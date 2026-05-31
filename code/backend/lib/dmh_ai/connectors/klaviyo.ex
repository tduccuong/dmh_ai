# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Klaviyo do
  @moduledoc """
  Klaviyo connector (Universal Region — email / SMS marketing). Case-B
  vendor-hosted MCP: Klaviyo runs the MCP server itself at
  `developers.klaviyo.com/.../klaviyo_mcp_server`, so there is no
  in-process REST translator and no `MCPHandler` subdir here. The
  dispatcher delegates to the vendor's MCP; the per-connector module
  owns slug + manifest + error remap + discovery seeds.

  Auth is **API key**, not OAuth — the second Case-B connector after
  Stripe to use this credential kind. The per-user credential row is
  `target='api_key:klaviyo'`, `kind='api_key'`, payload
  `{"api_key": "pk_..."}`.

  ## Vendor auth quirks (concerns of the vendor MCP server, not this module)

    * `Authorization: Klaviyo-API-Key <key>` — Klaviyo uses a custom
      auth scheme prefix instead of standard `Bearer`. The vendor's
      MCP server reads our `api_key` payload and inserts the
      `Klaviyo-API-Key` header on each upstream REST call.
    * `revision: 2024-10-15` — Klaviyo's REST surface is date-versioned;
      every request must carry a `revision` date header. Same delegation
      — the vendor MCP injects it.

  REST base for the docs: `https://a.klaviyo.com/api`.

  ## Layer B — per-user vendor metadata

  `discover_metadata/1` sweeps three Klaviyo endpoints (`/api/lists`,
  `/api/metrics`, `/api/segments`) with the user's `api_key:klaviyo`
  credential and caches one `connector_vendor_metadata` row per
  collection so `inspect_function_property` can answer id-lookup
  questions (`list_id`, `metric_id`, `segment_id`) from the cache.
  Each cache row carries a single synthetic property whose `options`
  enumerate the available ids — same name-match path the Brevo reader
  uses, so no special-casing in `inspect_property/3`.

  Fourteen functions at the SME-relevant slice:

    profile.find         [read]   look up profiles by email / query
    profile.create       [write]  create a new profile
    profile.update       [write]  patch an existing profile
    event.create         [write]  track an event for a profile
    event.find           [read]   browse tracked events (filterable by profile / metric)
    list.find            [read]   list audience lists
    list.create          [write]  create a new static list
    list.add_profile     [write]  add a profile to a list
    list.remove_profile  [write]  remove a profile from a list
    campaign.find        [read]   list campaigns (optionally filtered by status)
    segment.find         [read]   list dynamic segments (rule-driven, distinct from lists)
    flow.find            [read]   list marketing-automation flows
    template.find        [read]   list email templates
    metric.find          [read]   list tracked metrics ("Placed Order", "Opened Email", ...)

  ## List vs segment

  Klaviyo distinguishes **lists** (static, manually-managed membership)
  from **segments** (dynamic — membership is derived from rules each
  time). `list.create` / `list.add_profile` / `list.remove_profile`
  only act on lists; segments are read-only via `segment.find` because
  segment membership is a function of the segment's rules, not a
  collection mutated by the API.

  ## Membership endpoint shape

  Klaviyo exposes list membership as a JSON:API relationship:

      POST/DELETE /lists/{list_id}/relationships/profiles
      body: %{"data" => [%{"type" => "profile", "id" => "<profile_id>"}]}

  The vendor MCP server wraps `list_id` + `profile_id` into that
  envelope; the manifest declares the two flat args only.

  Klaviyo error contract (`/api/...` REST):
    * 429              → `:rate_limited`.
    * 404              → `:not_found`.
    * 401 / 403        → `:unauthorised`.
    * 409              → `:duplicate`.
    * JSON body shape `%{"errors" => [%{"code" => code, ...}, ...]}`
      drives canonical mapping when present (per-code mapping below).
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl true
  def mcp_slug, do: "klaviyo"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developers.klaviyo.com/en/reference/api_overview", title: "Klaviyo API overview"},
       %{url: "https://developers.klaviyo.com/en/reference/profiles_api_overview", title: "Klaviyo — Profiles API"},
       %{url: "https://developers.klaviyo.com/en/reference/events_api_overview", title: "Klaviyo — Events API"},
       %{url: "https://developers.klaviyo.com/en/reference/lists_api_overview", title: "Klaviyo — Lists API"},
       %{url: "https://developers.klaviyo.com/en/reference/campaigns_api_overview", title: "Klaviyo — Campaigns API"}
     ]}
  end

  # Klaviyo's REST surface is date-versioned — every request carries a
  # `revision` header pinning the API contract version. Bump this
  # constant when migrating to a newer Klaviyo revision.
  @klaviyo_revision "2024-10-15"

  # Per-user metadata sweep. Hits Klaviyo's `/api/lists`, `/api/metrics`,
  # and `/api/segments` endpoints and stores one
  # `connector_vendor_metadata` row per collection so the model can
  # later read the id enums (list_id, metric_id, segment_id) without
  # a live probe at compile time.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    case DmhAi.Auth.Credentials.lookup_all(user_id, "api_key:klaviyo") do
      [%{payload: %{"api_key" => key}} | _] when is_binary(key) ->
        sweep_layer_b(key)

      _ ->
        {:error, :no_klaviyo_credential}
    end
  end

  # Map a function bare-name to the Klaviyo cache row whose enum is the
  # source of truth for that function's id arg. `inspect_property/3`
  # uses this to route a property lookup at the cached metadata row
  # produced by `discover_metadata/1`.
  @function_to_cache %{
    "list.find"            => "lists",
    "list.add_profile"     => "lists",
    "list.remove_profile"  => "lists",
    "metric.find"          => "metrics",
    "event.find"           => "metrics",
    "event.create"         => "metrics",
    "segment.find"         => "segments"
  }

  # Layer B reader. Same shape as Brevo's: consult the metadata cache
  # populated by `discover_metadata/1`, locate the matching property by
  # exact name and return its type, label, and the vendor's option list.
  #
  # Returns `:not_supported` when:
  #   * the function name doesn't map to a known cache row
  #   * the user hasn't run Discover Metadata yet (cache empty)
  #   * the requested property isn't in the cached schema
  @impl true
  def inspect_property(function_name, path, ctx) do
    with cache_path when is_binary(cache_path) <- Map.get(@function_to_cache, function_name),
         %{schema: %{"properties" => props}} when is_list(props) <-
           Enum.find(ctx[:vendor_metadata] || [], fn r -> r.path == cache_path end),
         %{} = prop <- Enum.find(props, fn p -> p["name"] == path end) do
      {:ok,
       %{
         type:        prop["type"],
         enum:        extract_enum(prop),
         description: prop["label"],
         source:      :vendor_metadata
       }}
    else
      _ -> {:error, :not_supported}
    end
  end

  defp extract_enum(%{"options" => options}) when is_list(options) and options != [] do
    options
    |> Enum.map(fn o -> o["value"] end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_enum(_), do: nil

  defp sweep_layer_b(key) do
    headers = [
      {"authorization", "Klaviyo-API-Key " <> key},
      {"accept", "application/json"},
      {"revision", @klaviyo_revision}
    ]

    steps = [
      {"lists",    "https://a.klaviyo.com/api/lists?page[size]=100",    "list_id"},
      {"metrics",  "https://a.klaviyo.com/api/metrics?page[size]=100",  "metric_id"},
      {"segments", "https://a.klaviyo.com/api/segments?page[size]=100", "segment_id"}
    ]

    Enum.reduce_while(steps, {:ok, []}, fn {cache_path, url, prop_name}, {:ok, acc} ->
      case Req.get(url, headers: headers, finch: DmhAi.Finch, receive_timeout: 8_000) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          schema = build_id_enum_row(cache_path, prop_name, body)
          {:cont, {:ok, acc ++ [%{path: cache_path, schema: schema, expires_at: nil}]}}

        {:ok, %{status: s, body: body}} ->
          {:halt, {:error, {:http, s, body}}}

        {:error, reason} ->
          {:halt, {:error, {:transport, reason}}}
      end
    end)
  end

  # Klaviyo's collection endpoints return JSON:API:
  #   %{"data" => [%{"id" => "...", "type" => "list",
  #                 "attributes" => %{"name" => "..."}}, ...], "links" => ...}
  # The id sits at the top level of each data element; the human-readable
  # name is under `attributes.name`. Build one synthetic id property
  # whose `options` enumerate the collection — same shape Brevo uses for
  # its synthesised `list_id` row, so `inspect_property/3` resolves via
  # the same name-match path.
  defp build_id_enum_row(cache_path, prop_name, body) do
    options = extract_jsonapi_options(body)

    %{
      "object_type" => cache_path,
      "properties"  => [
        %{"name" => prop_name, "type" => "string", "options" => options}
      ]
    }
  end

  defp extract_jsonapi_options(%{"data" => data}) when is_list(data) do
    Enum.map(data, fn item ->
      %{
        "value" => item["id"],
        "label" => get_in(item, ["attributes", "name"])
      }
    end)
  end

  defp extract_jsonapi_options(_), do: []

  @impl true
  def credential_kind, do: :api_key

  @impl true
  def manifest do
    %Manifest{
      connector: "klaviyo",
      region:    "universal",
      functions: %{
        # vendor: GET /api/profiles
        "profile.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string, required: false, format: :email},
            "query" => %{type: :string, required: false}
          },
          returns: %{profiles: :list}
        },

        # vendor: POST /api/profiles
        "profile.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "email"        => %{type: :string, required: true, format: :email,
                                provenance: %{kind: :from_user}},
            "first_name"   => %{type: :string, required: false},
            "last_name"    => %{type: :string, required: false},
            "phone_number" => %{type: :string, required: false}
          },
          returns: %{profile_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited]
        },

        # vendor: PATCH /api/profiles/{id}
        # `patch` is a free-form map of Klaviyo profile fields → values;
        # the vendor MCP wraps it under the JSON:API `{"data":
        # {"type":"profile","attributes":{...}}}` envelope so any field
        # passes through unchanged.
        "profile.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "profile_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "klaviyo.profile.find"}},
            "patch"      => %{type: :map,    required: true,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{profile_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited]
        },

        # vendor: POST /api/events (track an event for a profile)
        "event.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "event_name"    => %{type: :string, required: true,
                                 provenance: %{kind: :from_user}},
            "profile_email" => %{type: :string, required: true, format: :email,
                                 provenance: %{kind: :from_user}},
            "properties"    => %{type: :map,    required: false}
          },
          returns: %{event_id: :string},
          errors:  [:unauthorised, :rate_limited]
        },

        # vendor: GET /api/lists
        "list.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{lists: :list}
        },

        # vendor: GET /api/campaigns
        "campaign.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "status" => %{type: :string,  required: false},
            "limit"  => %{type: :integer, required: false}
          },
          returns: %{campaigns: :list}
        },

        # vendor: POST /api/lists (static list — distinct from segments)
        "list.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name" => %{type: :string, required: true,
                        provenance: %{kind: :from_user}}
          },
          returns: %{list_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited]
        },

        # vendor: POST /api/lists/{list_id}/relationships/profiles
        # The vendor MCP wraps `list_id` + `profile_id` into the
        # JSON:API relationship envelope (see module doc).
        "list.add_profile" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "list_id"    => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "klaviyo.list.find"}},
            "profile_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "klaviyo.profile.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited]
        },

        # vendor: DELETE /api/lists/{list_id}/relationships/profiles
        # Same JSON:API relationship envelope as the add path.
        "list.remove_profile" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "list_id"    => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "klaviyo.list.find"}},
            "profile_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "klaviyo.profile.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited]
        },

        # vendor: GET /api/segments (dynamic, rule-driven — read-only;
        # see module doc on list vs segment).
        "segment.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{segments: :list}
        },

        # vendor: GET /api/flows
        "flow.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "status" => %{type: :string,  required: false},
            "limit"  => %{type: :integer, required: false}
          },
          returns: %{flows: :list}
        },

        # vendor: GET /api/templates
        "template.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{templates: :list}
        },

        # vendor: GET /api/metrics
        # Klaviyo's tracked metric registry — "Placed Order",
        # "Opened Email", etc. The id is required as the
        # `metric_id` filter input on `event.find`.
        "metric.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{metrics: :list}
        },

        # vendor: GET /api/events
        # Optional `filter` query string slices by profile / metric;
        # without filters returns the recent-events stream.
        "event.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "profile_id" => %{type: :string,  required: false,
                              provenance: %{kind: :lookup,
                                            source: "klaviyo.profile.find"}},
            "metric_id"  => %{type: :string,  required: false,
                              provenance: %{kind: :lookup,
                                            source: "klaviyo.metric.find"}},
            "limit"      => %{type: :integer, required: false}
          },
          returns: %{events: :list}
        }
      }
    }
  end

  @impl true
  # Klaviyo REST errors arrive shaped as JSON:API errors:
  #   %{"errors" => [%{"code" => code, "title" => ..., "detail" => ...,
  #                   "status" => http_status}, ...]}
  # Map the leading error's `code` to the canonical vocabulary.
  def remap_error(%{"errors" => [%{"code" => code} | _]}) when is_binary(code) do
    cond do
      code in ["duplicate_profile", "email_already_subscribed"] -> :duplicate
      code in ["not_authenticated", "invalid_api_key"]          -> :unauthorised
      code in ["resource_not_found"]                              -> :not_found
      code in ["rate_limit_exceeded", "throttled"]              -> :rate_limited
      true                                                        -> :passthrough
    end
  end

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 409, _}), do: :duplicate
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough
end
