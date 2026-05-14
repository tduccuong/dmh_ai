# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace do
  @moduledoc """
  Google Workspace connector (Universal Region, Case B — Gmail /
  Calendar / Drive via the official Google APIs).

  ## Vendor source-of-truth

  Each verb is grounded in a documented Google REST API endpoint;
  the MCP server (Google's official Cloud MCP catalog, or our own
  thin wrapper) is a JSON-RPC translation layer over those
  endpoints. Verb names in this manifest follow SME-ergonomic
  shapes — the wrapper translates each manifest arg to the
  endpoint's actual parameter name. The `# vendor: <endpoint>`
  comment on every verb is the auditable link back to the docs.

  Verb-to-endpoint mapping (also documented in
  `arch_wiki/dmh_ai/sme/layer-0.md` §0.3.2):

    | Verb                  | Endpoint                                          |
    |-----------------------|---------------------------------------------------|
    | gmail.search          | users.messages.list (Gmail API v1)                |
    | gmail.send            | users.messages.send (Gmail API v1)                |
    | gcal.find_free_slots  | freebusy.query + shim slot-computation (Cal v3)   |
    | gcal.create_event     | events.insert (Calendar API v3)                   |
    | drive.list            | files.list (Drive API v3)                         |
    | drive.upload          | files.create multipart (Drive API v3)             |

  ## Vendor quirks (`remap_error/1`)

    * 429 / `RESOURCE_EXHAUSTED` / `rateLimitExceeded` → `:rate_limited`
    * 404 / `NOT_FOUND` / `notFound` → `:not_found`
    * 401 / `UNAUTHENTICATED` / `invalidCredentials` → `:unauthorised`
    * 403 / `PERMISSION_DENIED` (insufficient OAuth scope) → `:unauthorised`
    * `ALREADY_EXISTS` → `:duplicate`
  """

  use DmhAi.Connectors.MCPAdapter
  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Verb

  @impl true
  def mcp_slug, do: "google_workspace"

  @impl true
  def manifest do
    %Manifest{
      connector: "google_workspace",
      region:    "universal",
      verbs: %{
        # vendor: GET https://gmail.googleapis.com/gmail/v1/users/me/messages
        # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/list
        # shim translation: manifest arg `query` → API arg `q` (Gmail
        # search syntax); `limit` → `maxResults`. Returns the raw
        # `messages[]` list with `id` + `threadId`; if the wrapper
        # fans out to users.messages.get for headers, that's an
        # opaque optimisation — the verb's return shape doesn't
        # promise headers in v1.
        "gmail.search" => %Verb{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string, required: true},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{messages: :list},
          scopes:  ["https://www.googleapis.com/auth/gmail.readonly"]
        },

        # vendor: POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send
        # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/send
        # shim translation: manifest args `to`/`subject`/`body` →
        # composed RFC-2822 MIME, base64url-encoded as the API's
        # `raw` field on the Message resource. Plain-text only in
        # v1; HTML alternative + attachments deferred (would
        # require multipart MIME — out of scope for the first
        # vertical demo).
        "gmail.send" => %Verb{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "to"      => %{type: :string, required: true, format: :email},
            "subject" => %{type: :string, required: true},
            "body"    => %{type: :string, required: true}
          },
          returns: %{message_id: :string},
          errors:  [:unauthorised, :rate_limited, :upstream_5xx],
          scopes:  ["https://www.googleapis.com/auth/gmail.send"]
        },

        # vendor: POST https://www.googleapis.com/calendar/v3/freeBusy
        # docs:   https://developers.google.com/calendar/api/v3/reference/freebusy/query
        # shim translation: the API returns BUSY intervals per
        # calendar/user. The MCP shim wraps `freebusy.query` and
        # **computes** free slots of length `duration_min` within
        # `[between_from, between_to]` by inverting the busy set
        # — this is genuine value-add on top of the raw API, not a
        # 1:1 translation. `between_from` / `between_to` must be
        # RFC-3339 with timezone (e.g.
        # `2026-05-14T09:00:00+02:00`).
        "gcal.find_free_slots" => %Verb{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "duration_min" => %{type: :integer, required: true},
            "between_from" => %{type: :string,  required: true},
            "between_to"   => %{type: :string,  required: true},
            "attendees"    => %{type: :list,    required: false}
          },
          returns: %{slots: :list},
          scopes:  ["https://www.googleapis.com/auth/calendar.readonly"]
        },

        # vendor: POST https://www.googleapis.com/calendar/v3/calendars/primary/events
        # docs:   https://developers.google.com/calendar/api/v3/reference/events/insert
        # shim translation: manifest arg `title` → API field
        # `summary`; `start` / `end` → `start.dateTime` /
        # `end.dateTime` (both RFC-3339 with timezone);
        # `attendees` → list of `%{"email" => ...}` objects.
        # Calendar id defaults to `primary` — multi-calendar
        # creation deferred.
        "gcal.create_event" => %Verb{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "title"     => %{type: :string, required: true},
            "start"     => %{type: :string, required: true},
            "end"       => %{type: :string, required: true},
            "attendees" => %{type: :list,   required: false}
          },
          returns: %{event_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/calendar.events"]
        },

        # vendor: GET https://www.googleapis.com/drive/v3/files
        # docs:   https://developers.google.com/drive/api/v3/reference/files/list
        # shim translation: manifest arg `folder_id` → API arg `q`
        # as `"'<folder_id>' in parents"`; manifest arg `query`
        # passes through verbatim into `q` (Drive search syntax).
        # If both are provided the shim ANDs them.
        "drive.list" => %Verb{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "folder_id" => %{type: :string, required: false},
            "query"     => %{type: :string, required: false}
          },
          returns: %{items: :list},
          scopes:  ["https://www.googleapis.com/auth/drive.readonly"]
        },

        # vendor: POST https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart
        # docs:   https://developers.google.com/drive/api/v3/reference/files/create
        # shim translation: manifest args `name` / `mime_type` →
        # multipart metadata part; `content` → multipart media
        # part. The shim handles base64 boundary encoding and
        # defaults `mime_type` to `application/octet-stream` when
        # omitted. Resumable upload (`uploadType=resumable`) is
        # deferred until file-size > 5 MB becomes a real
        # constraint.
        "drive.upload" => %Verb{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"       => %{type: :string, required: true},
            "content"    => %{type: :string, required: true},
            "mime_type"  => %{type: :string, required: false}
          },
          returns: %{file_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/drive.file"]
        }
      }
    }
  end

  @impl true
  # Google APIs return errors as
  #   {"error": {"code": <int>, "status": "<UPPER_SNAKE>", "message":…}}
  # or with `errors: [{"reason": "<lowerCamelCase>"}]` on the v1 surfaces.
  def remap_error(%{"error" => %{"status" => status}}) do
    case status do
      "RESOURCE_EXHAUSTED"  -> :rate_limited
      "NOT_FOUND"           -> :not_found
      "UNAUTHENTICATED"     -> :unauthorised
      "PERMISSION_DENIED"   -> :unauthorised
      "ALREADY_EXISTS"      -> :duplicate
      _                     -> :passthrough
    end
  end

  def remap_error(%{"error" => %{"errors" => [%{"reason" => reason} | _]}}) do
    case reason do
      "rateLimitExceeded"     -> :rate_limited
      "userRateLimitExceeded" -> :rate_limited
      "notFound"              -> :not_found
      "invalidCredentials"    -> :unauthorised
      "authError"             -> :unauthorised
      _                       -> :passthrough
    end
  end

  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error(_), do: :passthrough

  @doc """
  OAuth catalog descriptor consumed by
  `Connectors.OAuthCatalogSeed.upsert!/1` at boot. The scope set
  here mirrors what the per-verb manifest declares; expanding the
  manifest with a new scope-using verb means adding the scope here
  too.

  Operator supplies `DMH_AI_GW_CLIENT_ID` /
  `DMH_AI_GW_CLIENT_SECRET` from their own Google Cloud project
  (web-application OAuth client). On a fresh install with these
  unset, the catalog row exists but with empty client fields —
  authorize_service will fail-loud when the user tries.

  `access_type=offline` + `prompt=consent` ensure a refresh token
  is returned on every grant (Google omits it on subsequent
  grants by default).
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "google_workspace",
      display_name:           "Google Workspace",
      host_match:             "accounts.google.com",
      authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
      token_endpoint:         "https://oauth2.googleapis.com/token",
      scopes: [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/drive.file"
      ],
      client_id_env:          "DMH_AI_GW_CLIENT_ID",
      client_secret_env:      "DMH_AI_GW_CLIENT_SECRET",
      userinfo_endpoint:      "https://openidconnect.googleapis.com/v1/userinfo",
      userinfo_field_path:    "email",
      extra_auth_params:      %{"access_type" => "offline", "prompt" => "consent"}
    }
  end

  @doc """
  MCP catalog descriptor consumed by
  `Connectors.MCPCatalogSeed.upsert!/1` at boot. The MCP URL is
  read from `DMH_AI_GW_MCP_URL` — in production this points at
  Google's official Workspace MCP endpoint; in stage / demo it
  points at `Connectors.Mock.VendorMCPServer` running on the
  bind host.
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "google_workspace",
      name:        "Google Workspace",
      description: "Gmail, Calendar, and Drive via the Google MCP server",
      mcp_url_env: "DMH_AI_GW_MCP_URL",
      auth_kind:   :oauth,
      categories:  ["productivity", "email", "calendar", "storage"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor, consumed by
  `Connectors.Bootstrap.start_vendor_mocks_if_enabled/0` when the
  operator sets `DMH_AI_ENABLE_VENDOR_MOCKS=true`. The mock binds
  to 127.0.0.1 on the port named by `DMH_AI_GW_MOCK_PORT`
  (default 8086) and serves the canned fixtures from
  `Connectors.Mock.Fixtures.GoogleWorkspace`. Production installs
  leave the flag off; the descriptor is inert without it.
  """
  def mock_descriptor do
    %{
      instance:     "demo_gw",
      port_env:     "DMH_AI_GW_MOCK_PORT",
      default_port: 8086,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.GoogleWorkspace.fixtures()
    }
  end

  @doc """
  Points the in-process `Connectors.MCPServer` at the connector's
  REST verb handler. Returns the module that exposes
  `handler/0` (the `slug` + `verbs` map the server registers). The
  `MCPServer` boot path enumerates every connector exposing this
  callback; no central list to update when a connector is added.
  """
  def mcp_handler_module, do: DmhAi.Connectors.GoogleWorkspace.MCPHandler
end
