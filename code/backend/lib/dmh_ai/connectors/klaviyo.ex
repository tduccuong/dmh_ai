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

  Six functions at the SME-relevant slice:

    profile.find     [read]   look up profiles by email / query
    profile.create   [write]  create a new profile
    profile.update   [write]  patch an existing profile
    event.create     [write]  track an event for a profile
    list.find        [read]   list audience lists
    campaign.find    [read]   list campaigns (optionally filtered by status)

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
