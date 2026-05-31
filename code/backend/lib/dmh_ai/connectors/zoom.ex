# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Zoom do
  @moduledoc """
  Zoom connector (Universal Region, Case B — vendor MCP).

  Seventeen functions at the SME-relevant slice of Zoom's REST API
  (developers.zoom.us) — meetings, recordings, users, webinars:

    meeting.create            [write]  schedule a meeting for the authed user
    meeting.find              [read]   list the authed user's meetings
    meeting.get               [read]   read one meeting by id
    meeting.update            [write]  patch an existing meeting
    meeting.delete            [write]  delete a meeting
    meeting.list_registrants  [read]   list registrants for a meeting
    meeting.add_registrant    [write]  add a registrant to a meeting
    meeting.list_participants [read]   list participants of a past meeting (Reports API)
    recording.find            [read]   list the authed user's cloud recordings
    recording.get             [read]   read recording files for one meeting
    recording.delete          [write]  trash / delete cloud recordings for one meeting
    user.find                 [read]   read a user (defaults to the authed user)
    user.find_by_email        [read]   identity pivot — resolve email → Zoom user id
    webinar.create            [write]  schedule a webinar for the authed user
    webinar.find              [read]   list the authed user's webinars
    webinar.add_registrant    [write]  add a registrant to a webinar
    webinar.update            [write]  patch an existing webinar

  Four capability groups (meetings / recordings / users / webinars)
  so admins can scope per-org — a scheduling-only org might tick
  meetings, while a webinar org also enables webinars.

  ## Fixed host, Bearer auth

  The Zoom REST API is a single fixed host (`https://api.zoom.us/v2`)
  — there is no per-account / per-instance templating. Every call uses
  standard `Authorization: Bearer <token>` auth, which `RestBridge`
  injects from `ctx.bearer_token`.

  ## Vendor quirk: numeric error codes (`remap_error/1`)

  Unlike Slack's HTTP-200-on-failure model, Zoom returns normal HTTP
  status codes with a JSON error body of the shape
  `%{"code" => <int>, "message" => ...}`. So the success path keys off
  the HTTP status, and `remap_error/1` pattern-matches Zoom's numeric
  code first (`124` invalid access token → `:unauthorised`; `1001`
  user not found → `:not_found`; `3001` meeting not found →
  `:not_found`) before falling back to the HTTP-status tuples. Zoom
  has no strong duplicate concept, so there is no `:duplicate` mapping.

  ## Path-param ids

  Functions acting on a specific object (`meeting.get` / `meeting.update`
  / `meeting.delete`, and `user.find` for a non-self user) interpolate
  the id into the URL path. The id is whitelisted to `^[A-Za-z0-9_-]+$`
  in the MCP handler before the URL is built — no raw interpolation of
  unvalidated input.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(access_token) when is_binary(access_token) do
    # Zoom's `/users/me` returns the connecting user's id + email. The
    # access token goes in standard Bearer auth. Response:
    #   `{"id": ..., "email": ..., ...}`.
    url = "https://api.zoom.us/v2/users/me"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: %{"id" => uid, "email" => email}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email, id: to_string(uid)}}

      {:ok, %{status: 200, body: %{"email" => email}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email}}

      {:ok, %{status: s, body: body}} ->
        {:error, {:http, s, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp http_get(url, access_token) do
    case Application.get_env(:dmh_ai, :__zoom_userinfo_stub__) do
      nil ->
        Req.get(url,
          headers: [{"authorization", "Bearer " <> access_token}],
          finch: DmhAi.Finch,
          receive_timeout: 5_000,
          retry: false
        )

      stub ->
        stub.(url, access_token)
    end
  end

  @impl true
  def mcp_slug, do: "zoom"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developers.zoom.us/docs/api/", title: "Zoom API reference"},
       %{url: "https://developers.zoom.us/docs/api/meetings/", title: "Zoom — Meetings API"},
       %{url: "https://developers.zoom.us/docs/api/webinars/", title: "Zoom — Webinars API"},
       %{url: "https://developers.zoom.us/docs/api/cloud-recording/", title: "Zoom — Cloud Recording API"},
       %{url: "https://developers.zoom.us/docs/api/users/", title: "Zoom — Users API"},
       %{url: "https://developers.zoom.us/docs/integrations/oauth/", title: "Zoom — OAuth"}
     ]}
  end

  # Per-user metadata sweep. Zoom has no per-user custom-property
  # schema analogous to HubSpot's `/crm/v3/properties/<object>` — its
  # objects are fixed-shape. So there is nothing to sweep: always
  # return an empty row set (no metadata to cache) — same contract as
  # the other Case-B connectors.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    {:ok, []}
  end

  # Layer B reader. Zoom objects are fixed-shape with no custom
  # property schema to introspect, so there is no metadata cache to
  # consult. Always return `:not_supported`, which the compiler treats
  # as "trust the literal" — same contract as the default.
  @impl true
  def inspect_property(_function_name, _path, _ctx), do: {:error, :not_supported}

  @impl true
  def manifest do
    %Manifest{
      connector: "zoom",
      region:    "universal",
      functions: %{
        # vendor: POST /users/me/meetings
        # docs:   https://developers.zoom.us/docs/api/meetings/
        "meeting.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "topic"      => %{type: :string,  required: true,
                              provenance: %{kind: :from_user}},
            "start_time" => %{type: :string,  required: false},
            "duration"   => %{type: :integer, required: false},
            "agenda"     => %{type: :string,  required: false}
          },
          returns: %{meeting_id: :string, join_url: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["meeting:write"]
        },

        # vendor: GET /users/me/meetings
        "meeting.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{meetings: :list},
          scopes:  ["meeting:read"]
        },

        # vendor: GET /meetings/{meeting_id}
        "meeting.get" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "meeting_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.meeting.find"}}
          },
          returns: %{meeting: :map},
          scopes:  ["meeting:read"]
        },

        # vendor: PATCH /meetings/{meeting_id}
        # `patch` is a free-form map of Zoom meeting fields → values;
        # the shim does not enumerate or validate field names so any
        # field passes through.
        "meeting.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "meeting_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.meeting.find"}},
            "patch"      => %{type: :map,    required: true,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{meeting_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["meeting:write"]
        },

        # vendor: DELETE /meetings/{meeting_id}
        "meeting.delete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "meeting_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.meeting.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["meeting:write"]
        },

        # vendor: GET /users/me/recordings
        "recording.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "from"  => %{type: :string,  required: false},
            "to"    => %{type: :string,  required: false},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{recordings: :list},
          scopes:  ["recording:read"]
        },

        # vendor: GET /users/{user_id_or_me}
        "user.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "user_id" => %{type: :string, required: false,
                           provenance: %{kind: :from_user}}
          },
          returns: %{user: :map},
          scopes:  ["user:read"]
        },

        # vendor: POST /users/me/webinars
        "webinar.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "topic"      => %{type: :string,  required: true,
                              provenance: %{kind: :from_user}},
            "start_time" => %{type: :string,  required: false},
            "duration"   => %{type: :integer, required: false}
          },
          returns: %{webinar_id: :string, registration_url: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["webinar:write"]
        },

        # vendor: GET /meetings/{meeting_id}/registrants
        # docs:   https://developers.zoom.us/docs/api/meetings/
        "meeting.list_registrants" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "meeting_id" => %{type: :string,  required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.meeting.find"}},
            "status"     => %{type: :string,  required: false,
                              provenance: %{kind: :literal_default,
                                            value: "approved"}},
            "limit"      => %{type: :integer, required: false}
          },
          returns: %{registrants: :list},
          scopes:  ["meeting:read"]
        },

        # vendor: POST /meetings/{meeting_id}/registrants
        "meeting.add_registrant" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "meeting_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.meeting.find"}},
            "email"      => %{type: :string, required: true, format: :email,
                              provenance: %{kind: :from_user}},
            "first_name" => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "last_name"  => %{type: :string, required: false}
          },
          returns: %{registrant_id: :string, join_url: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["meeting:write"]
        },

        # vendor: GET /report/meetings/{meeting_uuid}/participants
        # Reports API — requires the coarse `report:read:admin` scope
        # (no narrower meeting-scoped read alternative exists). The
        # `meeting_uuid` arg is double-encoded before path interpolation
        # because Zoom UUIDs may contain `/` and `+`.
        "meeting.list_participants" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "meeting_uuid" => %{type: :string,  required: true,
                                provenance: %{kind: :from_user}},
            "limit"        => %{type: :integer, required: false}
          },
          returns: %{participants: :list},
          scopes:  ["report:read:admin"]
        },

        # vendor: GET /meetings/{meeting_id}/recordings
        "recording.get" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "meeting_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.meeting.find"}}
          },
          returns: %{recording: :map},
          scopes:  ["recording:read"]
        },

        # vendor: DELETE /meetings/{meeting_id}/recordings?action={action}
        # `action`: `trash` (recoverable) or `delete` (permanent).
        "recording.delete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "meeting_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.meeting.find"}},
            "action"     => %{type: :string, required: false,
                              provenance: %{kind: :literal_default,
                                            value: "trash"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["recording:write"]
        },

        # vendor: GET /users/me/webinars
        "webinar.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{webinars: :list},
          scopes:  ["webinar:read"]
        },

        # vendor: POST /webinars/{webinar_id}/registrants
        "webinar.add_registrant" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "webinar_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.webinar.find"}},
            "email"      => %{type: :string, required: true, format: :email,
                              provenance: %{kind: :from_user}},
            "first_name" => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "last_name"  => %{type: :string, required: false}
          },
          returns: %{registrant_id: :string, join_url: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["webinar:write"]
        },

        # vendor: PATCH /webinars/{webinar_id}
        # `patch` is a free-form map of Zoom webinar fields → values;
        # the shim does not enumerate or validate field names so any
        # field passes through.
        "webinar.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "webinar_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "zoom.webinar.find"}},
            "patch"      => %{type: :map,    required: true,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{webinar_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["webinar:write"]
        },

        # vendor: GET /users/{email}
        # docs:   https://developers.zoom.us/docs/api/users/
        # Identity pivot — Zoom's `/users/{id}` endpoint accepts an
        # email (or userId) as the path id, returning the Zoom user
        # resource. `user:read:admin` is required for arbitrary-email
        # lookup; the narrower `user:read` only resolves the authed
        # user. The email path param is URL-escaped before
        # interpolation (`@` + `.` are URI-safe but consistent
        # encoding is cleaner; the same helper handles `+` aliases).
        "user.find_by_email" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string, required: true, format: :email,
                         provenance: %{kind: :from_user}}
          },
          returns: %{user: :map},
          scopes:  ["user:read:admin"]
        }
      }
    }
  end

  @impl true
  # `user.find_by_email` hits Zoom's `/users/{email}` lookup — Zoom's
  # `/users/{id}` endpoint accepts an email (or userId) as the path
  # id and returns the Zoom user resource. Emits the user object's
  # `id`, which is what downstream assignment fields expect.
  def identity_lookup,
    do: %{function: "zoom.user.find_by_email", by_arg: :email, emit_field: "id"}

  @impl true
  # Zoom returns normal HTTP status codes with a JSON error body of the
  # shape `%{"code" => <int>, "message" => ...}`. The leading clauses
  # key off the numeric code and map it to the canonical class; the
  # HTTP-status tuples below cover transport-level failures (e.g. a
  # naked 5xx before Zoom frames a JSON body). Zoom has no strong
  # duplicate concept, so there is no `:duplicate` mapping.
  def remap_error(%{"code" => 124}), do: :unauthorised
  def remap_error(%{"code" => 1001}), do: :not_found
  def remap_error(%{"code" => 3001}), do: :not_found
  def remap_error(%{"code" => code}) when is_integer(code), do: :passthrough

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Zoom OAuth lives at
  `zoom.us/oauth/authorize` (consent) + `zoom.us/oauth/token`
  (exchange). Fixed host, no per-instance templating.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "zoom",
      display_name:           "Zoom",
      host_match:             "zoom.us",
      authorization_endpoint: "https://zoom.us/oauth/authorize",
      token_endpoint:         "https://zoom.us/oauth/token",
      # Zoom moved to granular scopes (e.g. `meeting:write:meeting`) in
      # 2024 — these classic scope names may need updating for live OAuth.
      # `report:read:admin` is the coarse admin scope the Reports API
      # demands (no narrower equivalent exists for
      # `meeting.list_participants`). `user:read:admin` is the
      # arbitrary-email lookup scope for `user.find_by_email` — the
      # narrower `user:read` only resolves the authed user.
      scopes: [
        "meeting:read",
        "meeting:write",
        "recording:read",
        "recording:write",
        "report:read:admin",
        "user:read",
        "user:read:admin",
        "webinar:read",
        "webinar:write"
      ],
      userinfo_endpoint:      "https://api.zoom.us/v2/users/me",
      userinfo_field_path:    "email",
      extra_auth_params:      %{}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Admin sets `mcp_url`
  via External Connectors (pre-filled to the in-process default).
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "zoom",
      name:        "Zoom",
      description: "Zoom — schedule/manage meetings, webinars, recordings.",
      auth_kind:   :oauth,
      categories:  ["meetings", "communication"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (Zoom-style meeting /
  user / webinar IDs) so chain results are mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_zoom",
      port_env:     "DMH_AI_ZOOM_MOCK_PORT",
      default_port: 8093,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.Zoom.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the Zoom MCP as an in-process REST translator on the
  shared real-MCP port. FE pre-fills this in the External Connectors
  form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/zoom"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount Zoom on the shared
  in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.Zoom.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Four
  domain groups go live — meetings / recordings / users / webinars
  — so a scheduling-only org can expose meetings and skip the rest,
  while a webinar org also enables webinars. The three enforcement
  layers (OAuth scope filter, tool catalog filter, dispatcher gate)
  all read from `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "meetings",
        display_name: "Meetings",
        description:  "Schedule, read, update, delete meetings; manage registrants and inspect participants.",
        scopes:       ["meeting:read", "meeting:write", "report:read:admin"],
        functions:    [
          "meeting.create",
          "meeting.find",
          "meeting.get",
          "meeting.update",
          "meeting.delete",
          "meeting.list_registrants",
          "meeting.add_registrant",
          "meeting.list_participants"
        ],
        vendor_prereq: %{
          label:      "Zoom OAuth app scopes (Meetings)",
          enable_url: "https://developers.zoom.us/docs/integrations/oauth/"
        }
      },
      %{
        id:           "recordings",
        display_name: "Recordings",
        description:  "List, read, and delete cloud recordings.",
        scopes:       ["recording:read", "recording:write"],
        functions:    ["recording.find", "recording.get", "recording.delete"],
        vendor_prereq: %{
          label:      "Zoom OAuth app scopes (Recordings)",
          enable_url: "https://developers.zoom.us/docs/integrations/oauth/"
        }
      },
      %{
        id:           "users",
        display_name: "Users",
        description:  "Look up Zoom users (by id or email — identity lookup).",
        scopes:       ["user:read", "user:read:admin"],
        functions:    ["user.find", "user.find_by_email"],
        vendor_prereq: %{
          label:      "Zoom OAuth app scopes (Users)",
          enable_url: "https://developers.zoom.us/docs/integrations/oauth/",
          help:       "user:read:admin is an admin-tier scope. Without it, arbitrary-email lookups against /users/{email} return 4xx (Zoom restricts the endpoint to admin-scoped contexts when keyed by anything other than the authed user). The narrower user:read scope only resolves /users/me."
        }
      },
      %{
        id:           "webinars",
        display_name: "Webinars",
        description:  "Schedule, list, update webinars; add registrants.",
        scopes:       ["webinar:read", "webinar:write"],
        functions:    [
          "webinar.create",
          "webinar.find",
          "webinar.add_registrant",
          "webinar.update"
        ],
        vendor_prereq: %{
          label:      "Zoom OAuth app scopes (Webinars)",
          enable_url: "https://developers.zoom.us/docs/integrations/oauth/"
        }
      }
    ]
  end

end
