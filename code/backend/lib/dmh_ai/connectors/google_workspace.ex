# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace do
  @moduledoc """
  Google Workspace connector (Universal Region, Case B — Gmail /
  Calendar / Drive via the official Google APIs).

  ## Vendor source-of-truth

  Each function is grounded in a documented Google REST API endpoint;
  the MCP server (Google's official Cloud MCP catalog, or our own
  thin wrapper) is a JSON-RPC translation layer over those
  endpoints. Function names in this manifest follow SME-ergonomic
  shapes — the wrapper translates each manifest arg to the
  endpoint's actual parameter name. The `# vendor: <endpoint>`
  comment on every function is the auditable link back to the docs.

  Function-to-endpoint mapping (also documented in
  `arch_wiki/dmh_ai/sme/layer-0.md` §0.3.2):

    | Function                  | Endpoint                                          |
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
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function
  alias DmhAi.Connectors.GoogleWorkspace.LiveProbe

  require Logger

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(token),
    do: DmhAi.OAuth.Identity.OIDC.fetch(token,
          "https://openidconnect.googleapis.com/v1/userinfo", "email")

  @impl true
  def mcp_slug, do: "google_workspace"

  # Mapping from our connector function name to the Google API method
  # that backs it. The `discover_functions/0` callback probes each
  # entry's live Discovery Document and overlays the live `scopes`
  # field onto the matching priv-seed row. Functions absent from this
  # map (synthetic recipes, multi-call composites) pass through from
  # the priv baseline unchanged — they have no 1:1 Google method.
  @google_method_map %{
    "gmail.search"       => {"gmail",    "v1", "gmail.users.messages.list"},
    "gmail.send"         => {"gmail",    "v1", "gmail.users.messages.send"},
    "gmail.reply"        => {"gmail",    "v1", "gmail.users.messages.send"},
    "calendar.list"      => {"calendar", "v3", "calendar.events.list"},
    "calendar.create"    => {"calendar", "v3", "calendar.events.insert"},
    "drive.upload"       => {"drive",    "v3", "drive.files.create"},
    "drive.list"         => {"drive",    "v3", "drive.files.list"},
    "drive.read"         => {"drive",    "v3", "drive.files.get"},
    "docs.create"        => {"docs",     "v1", "docs.documents.create"},
    "sheets.read"        => {"sheets",   "v4", "sheets.spreadsheets.values.get"},
    "tasks.list"         => {"tasks",    "v1", "tasks.tasks.list"},
    "tasks.create"       => {"tasks",    "v1", "tasks.tasks.insert"}
  }

  @impl DmhAi.Connectors.Discoverable
  def discover_functions do
    case DmhAi.Connectors.Seed.read_priv_rows(mcp_slug()) do
      {:ok, baseline} ->
        {:ok, overlay_live_scopes(baseline)}

      {:error, _} = err ->
        err
    end
  end

  # For each baseline row whose function_name has a Google Discovery
  # mapping, probe the live Discovery Document and verify the row's
  # `scopes_required` is still in Google's accepted list. Rows are
  # returned UNCHANGED — the probe's job here is verification, not
  # silent rewriting. A drift (declared scope absent from the live
  # list) emits a warning so the operator can investigate; an
  # auto-substitute would be guessing at Google's permission semantics
  # and could be wrong.
  defp overlay_live_scopes(rows) do
    Enum.map(rows, fn row ->
      case Map.get(@google_method_map, row.function_name) do
        nil ->
          row

        {api, version, method_id} ->
          case LiveProbe.probe_method(api, version, method_id) do
            {:ok, %{scopes: live_scopes}} when is_list(live_scopes) ->
              verify_scopes(row, live_scopes, method_id)
              row

            {:ok, _} ->
              row

            {:error, reason} ->
              Logger.warning(
                "[GoogleWorkspace.discover_functions] fn=#{row.function_name} probe " <>
                  "method=#{method_id} failed=#{inspect(reason)}; using priv baseline"
              )
              row
          end
      end
    end)
  end

  defp verify_scopes(row, live_scopes, method_id) do
    declared = Map.get(row, :scopes_required, [])
    drift    = declared -- live_scopes

    if drift != [] do
      Logger.warning(
        "[GoogleWorkspace.discover_functions] fn=#{row.function_name} method=#{method_id} " <>
          "declared scopes #{inspect(drift)} NOT in Google's accepted list " <>
          "#{inspect(live_scopes)} — bundled defaults may be out of date"
      )
    end

    :ok
  end

  @impl true
  def manifest do
    %Manifest{
      connector: "google_workspace",
      region:    "universal",
      functions: %{
        # vendor: GET https://gmail.googleapis.com/gmail/v1/users/me/messages
        # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/list
        # shim translation: manifest arg `query` → API arg `q` (Gmail
        # search syntax); `limit` → `maxResults`. Returns the raw
        # `messages[]` list with `id` + `threadId`; if the wrapper
        # fans out to users.messages.get for headers, that's an
        # opaque optimisation — the function's return shape doesn't
        # promise headers in v1.
        "gmail.search" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query"       => %{type: :string, required: true,
                               provenance: %{kind: :literal_default}},
            "limit"       => %{type: :integer, required: false},
            "after_epoch" => %{type: :integer, required: false}
          },
          returns: %{messages: :list},
          scopes:  ["https://www.googleapis.com/auth/gmail.readonly"],
          # Poll-trigger protocol. Cursor = unix-epoch seconds of the
          # newest message seen; the runtime passes it as `after_epoch`
          # on the next tick so the search narrows to genuinely-new
          # mail. The response's `next_cursor` carries the new value;
          # `items_path` is the `messages` array.
          poll_trigger_capable: true,
          cursor_arg:           "after_epoch",
          cursor_response_path: "$.next_cursor",
          items_path:           "$.messages",
          # Cadence: Gmail's list endpoint has plenty of quota
          # (250 units/user/s) but polling every second across many
          # users would still be wasteful + chatty. Floor at 30s,
          # default 5 min — covers "process incoming mail" without
          # burning quota.
          min_poll_seconds:     30,
          default_poll_seconds: 300
        },

        # vendor: POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send
        # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/send
        # shim translation: manifest args `to`/`subject`/`body` →
        # composed RFC-2822 MIME, base64url-encoded as the API's
        # `raw` field on the Message resource. Plain-text only in
        # v1; HTML alternative + attachments deferred (would
        # require multipart MIME — out of scope for the first
        # vertical demo).
        "gmail.send" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "to"      => %{type: :string, required: true, format: :email,
                           provenance: %{kind: :literal_default}},
            "subject" => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}},
            "body"    => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}}
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
        "gcal.find_free_slots" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            # 30 minutes is the de-facto SME meeting length (calendar
            # UIs default to it). Model can pick autonomously when the
            # user says "find me a slot" without specifying length.
            "duration_min" => %{type: :integer, required: true,
                                provenance: %{kind: :literal_default, value: 30}},
            "between_from" => %{type: :string,  required: true,
                                provenance: %{kind: :literal_default}},
            "between_to"   => %{type: :string,  required: true,
                                provenance: %{kind: :literal_default}},
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
        "gcal.create_event" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "title"     => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}},
            "start"     => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}},
            "end"       => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}},
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
        "drive.list" => %Function{
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
        "drive.upload" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"       => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "content"    => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "mime_type"  => %{type: :string, required: false}
          },
          returns: %{file_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/drive.file"]
        },

        # vendor: POST https://meet.googleapis.com/v2/spaces
        # docs:   https://developers.google.com/meet/api/reference/rest/v2/spaces/create
        # shim translation: empty body POST creates a fresh Meet
        # space; response carries `name` (space resource id) +
        # `meetingUri` (the join link a user shares with attendees)
        # + `meetingCode` (the dial-in code). No request args
        # today — the Meet "space" is just a reusable room. For
        # SME use cases ("give me a Meet link for now") this is
        # enough; deferred: setting `accessType` / co-host config
        # via Spaces.patch.
        "meet.create_meeting" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args:    %{},
          returns: %{join_url: :string, meeting_code: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/meetings.space.created"]
        },

        # vendor: GET  https://tasks.googleapis.com/tasks/v1/lists/@default/tasks
        # docs:   https://developers.google.com/tasks/reference/rest/v1/tasks/list
        "tasks.list" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{tasks: :list},
          scopes:  ["https://www.googleapis.com/auth/tasks.readonly"]
        },

        # vendor: POST https://tasks.googleapis.com/tasks/v1/lists/@default/tasks
        # docs:   https://developers.google.com/tasks/reference/rest/v1/tasks/insert
        # shim translation: `title` + optional `notes` + optional
        # `due` (RFC-3339 timestamp) → body `{title, notes, due}`.
        "tasks.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "title" => %{type: :string, required: true,
                         provenance: %{kind: :literal_default}},
            "notes" => %{type: :string, required: false},
            "due"   => %{type: :string, required: false}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/tasks"]
        },

        # vendor: GET https://people.googleapis.com/v1/people:searchContacts
        # docs:   https://developers.google.com/people/api/rest/v1/people/searchContacts
        # shim translation: `query` → API arg `query`; readMask
        # locked to `names,emailAddresses` since that's what the
        # model needs to resolve a name → email.
        "contacts.search" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string, required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{contacts: :list},
          scopes:  ["https://www.googleapis.com/auth/contacts.readonly"]
        },

        # vendor: GET https://sheets.googleapis.com/v4/spreadsheets/{id}/values/{range}
        # docs:   https://developers.google.com/sheets/api/reference/rest/v4/spreadsheets.values/get
        # shim translation: `spreadsheet_id` + `range` (A1
        # notation, e.g. "Sheet1!A1:C50") → response carries
        # `values: [[...row...], ...]` which the model can quote.
        "sheets.read_range" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            # No `sheets.list` verb in this connector — operators
            # paste the spreadsheet URL / id directly, or surface
            # it as a trigger input. `:lookup` would dangle.
            "spreadsheet_id" => %{type: :string, required: true,
                                  provenance: %{kind: :literal_default}},
            # A1 notation default that covers a generous read window
            # without paying for unbounded sheets.
            "range"          => %{type: :string, required: true,
                                  provenance: %{kind: :literal_default, value: "A1:Z1000"}}
          },
          returns: %{values: :list},
          scopes:  ["https://www.googleapis.com/auth/spreadsheets.readonly"]
        },

        # vendor: POST /gmail/v1/users/me/messages/send  (with threadId)
        # Replies attach a `threadId` + `In-Reply-To` header so Gmail
        # threads the reply correctly. Most agent-driven email is a
        # reply, not a cold send.
        "gmail.reply" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "thread_id"  => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "google_workspace.gmail.search"}},
            "to"         => %{type: :string, required: true, format: :email,
                              provenance: %{kind: :literal_default}},
            "subject"    => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "body"       => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "in_reply_to_message_id" => %{type: :string, required: false}
          },
          returns: %{message_id: :string},
          errors:  [:unauthorised, :rate_limited, :upstream_5xx],
          scopes:  ["https://www.googleapis.com/auth/gmail.send"]
        },

        # vendor: PATCH /calendar/v3/calendars/primary/events/{eventId}
        # The model uses this for "move my 3 PM with Brian to Thursday
        # at the same time" / "shift everything an hour later" prompts.
        "gcal.update_event" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            # No `gcal.events_list` verb today — operators paste
            # the event id (or it arrives as a trigger payload).
            "event_id"  => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}},
            "patch"     => %{type: :map,    required: true,
                             provenance: %{kind: :literal_default}}
          },
          returns: %{event_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/calendar.events"]
        },

        # vendor: GET /v1/documents/{documentId}
        # Returns the doc's textual content concatenated from its
        # `body.content` paragraphs — enough for "summarize this
        # doc" prompts without paying for the full document tree.
        "docs.read_text" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "document_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "google_workspace.drive.list"}}
          },
          returns: %{text: :string, title: :string},
          scopes:  ["https://www.googleapis.com/auth/documents.readonly"]
        }
      }
    }
  end

  @impl true
  # Primitive 0.9 — no Directory API function in this manifest yet,
  # so workflows can't resolve `@user_N` against Google Workspace.
  # Fix: add `directory.users.find_by_email` (GET
  # /admin/directory/v1/users/{userKey}) and switch this to:
  #   %{function: "google_workspace.directory.users.find_by_email",
  #     by_arg: :email, emit_field: "id"}
  def identity_lookup, do: nil

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
  OAuth catalog descriptor — vendor facts only. Consumed by
  `Connectors.OAuthCatalogSeed.upsert!/1` at boot to populate the
  oauth_catalog row's vendor-metadata columns (endpoints, scopes,
  host_match, etc.). Credentials (`client_id`, `client_secret`)
  are operator-set via the External Connectors admin page; the
  seeder never reads or writes them.

  The scope set here mirrors what the per-function manifest
  declares; expanding the manifest with a new scope-using
  function means adding the scope here too.

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
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/documents.readonly"
      ],
      # Identity capture lives in `fetch_userinfo/1` (see top of module).
      userinfo_endpoint:      nil,
      userinfo_field_path:    nil,
      extra_auth_params:      %{"access_type" => "offline", "prompt" => "consent"}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Consumed by
  `Connectors.MCPCatalogSeed.upsert!/1` at boot to populate the
  mcp_catalog row's vendor-metadata columns. The `mcp_url`
  (where the vendor's MCP server lives) is operator-set via the
  External Connectors admin page — in production it points at
  Google's official Workspace MCP endpoint; in stage / demo
  the admin pastes the local `Connectors.Mock.VendorMCPServer`
  URL. The seeder never writes mcp_url.
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "google_workspace",
      name:        "Google Workspace",
      description: "Gmail, Calendar, and Drive via the Google MCP server",
      auth_kind:   :oauth,
      categories:  ["productivity", "email", "calendar", "storage"]
    }
  end

  @doc """
  Where the GW MCP server is reachable in *this* deployment.
  DMH-AI hosts the Google Workspace MCP as an in-process REST
  translator (`DmhAi.Connectors.MCPServer`), so we know the URL
  without the admin having to look it up. The FE pre-fills the
  External Connectors form's MCP URL field with this value when
  the row is empty.

  Admin can override the pre-fill (e.g. point at the mock
  `127.0.0.1:8086` during a demo, or Google's official Cloud
  MCP URL when it goes GA); the DB row wins after the first
  Save.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/google_workspace"
  end

  @doc """
  Capability groups this connector exposes. Each group bundles:
    * `id` — short slug used in `mcp_catalog.enabled_capabilities`.
    * `display_name` / `description` — admin-facing copy.
    * `scopes` — OAuth scopes requested at Connect time when this
       capability is enabled.
    * `functions` — manifest function names that belong to this
       group. Layer-2 tools_list filter + Layer-3 dispatcher gate
       both consult this list to decide visibility/executability.
    * `vendor_prereq` — vendor-side setup (API to enable in Cloud
       Console). Rendered inline on each capability row in the
       admin FE so the admin clicks through without a separate
       checklist.

  Admin curates which subset to expose via External Connectors;
  three enforcement layers (OAuth scope at Connect, tool catalog
  filter, dispatcher gate) all read from
  `mcp_catalog.enabled_capabilities` for the slug.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "gmail",
        display_name: "Gmail",
        description:  "Read inbox messages and send mail on the user's behalf.",
        scopes: [
          "https://www.googleapis.com/auth/gmail.readonly",
          "https://www.googleapis.com/auth/gmail.send"
        ],
        functions: ["gmail.search", "gmail.send", "gmail.reply"],
        vendor_prereq: %{
          label:      "Gmail API",
          enable_url: "https://console.cloud.google.com/apis/library/gmail.googleapis.com"
        }
      },
      %{
        id:           "calendar",
        display_name: "Calendar",
        description:  "Read availability and create calendar events.",
        scopes: [
          "https://www.googleapis.com/auth/calendar.readonly",
          "https://www.googleapis.com/auth/calendar.events"
        ],
        functions: ["gcal.find_free_slots", "gcal.create_event", "gcal.update_event"],
        vendor_prereq: %{
          label:      "Calendar API",
          enable_url: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com"
        }
      },
      %{
        id:           "meet",
        display_name: "Meet",
        description:  "Create a Google Meet meeting on demand; the agent shares the join link.",
        scopes: [
          "https://www.googleapis.com/auth/meetings.space.created"
        ],
        functions: ["meet.create_meeting"],
        vendor_prereq: %{
          label:      "Google Meet REST API",
          enable_url: "https://console.cloud.google.com/apis/library/meet.googleapis.com"
        }
      },
      %{
        id:           "tasks",
        display_name: "Tasks",
        description:  "List the user's Google Tasks and add new ones.",
        scopes: [
          "https://www.googleapis.com/auth/tasks.readonly",
          "https://www.googleapis.com/auth/tasks"
        ],
        functions: ["tasks.list", "tasks.create"],
        vendor_prereq: %{
          label:      "Google Tasks API",
          enable_url: "https://console.cloud.google.com/apis/library/tasks.googleapis.com"
        }
      },
      %{
        id:           "contacts",
        display_name: "Contacts",
        description:  "Search the user's Google Contacts to resolve names to email addresses.",
        scopes: [
          "https://www.googleapis.com/auth/contacts.readonly"
        ],
        functions: ["contacts.search"],
        vendor_prereq: %{
          label:      "People API",
          enable_url: "https://console.cloud.google.com/apis/library/people.googleapis.com"
        }
      },
      %{
        id:           "sheets",
        display_name: "Sheets",
        description:  "Read cell ranges from the user's Google Sheets (read-only).",
        scopes: [
          "https://www.googleapis.com/auth/spreadsheets.readonly"
        ],
        functions: ["sheets.read_range"],
        vendor_prereq: %{
          label:      "Google Sheets API",
          enable_url: "https://console.cloud.google.com/apis/library/sheets.googleapis.com"
        }
      },
      # ── Planned (vendor surface visible to admins, not yet built) ──
      %{
        id:           "docs",
        display_name: "Docs",
        description:  "Read Google Docs content as plain text (for summarization, extraction).",
        scopes:       ["https://www.googleapis.com/auth/documents.readonly"],
        functions:    ["docs.read_text"],
        vendor_prereq: %{label: "Google Docs API", enable_url: "https://console.cloud.google.com/apis/library/docs.googleapis.com"}
      },
      %{
        id:           "slides",
        display_name: "Slides",
        description:  "Generate + edit Google Slides decks.",
        status:       :planned,
        scopes:       ["https://www.googleapis.com/auth/presentations"],
        functions:    [],
        vendor_prereq: %{label: "Google Slides API", enable_url: "https://console.cloud.google.com/apis/library/slides.googleapis.com"}
      },
      %{
        id:           "forms",
        display_name: "Forms",
        description:  "Read Google Forms responses.",
        status:       :planned,
        scopes:       ["https://www.googleapis.com/auth/forms.responses.readonly"],
        functions:    [],
        vendor_prereq: %{label: "Google Forms API", enable_url: "https://console.cloud.google.com/apis/library/forms.googleapis.com"}
      },
      %{
        id:           "chat",
        display_name: "Chat",
        description:  "Send Google Chat messages to spaces / DMs.",
        status:       :planned,
        scopes:       ["https://www.googleapis.com/auth/chat.messages.create"],
        functions:    [],
        vendor_prereq: %{label: "Google Chat API", enable_url: "https://console.cloud.google.com/apis/library/chat.googleapis.com"}
      },
      %{
        id:           "youtube",
        display_name: "YouTube",
        description:  "Read the user's YouTube channel + video metadata.",
        status:       :planned,
        scopes:       ["https://www.googleapis.com/auth/youtube.readonly"],
        functions:    [],
        vendor_prereq: %{label: "YouTube Data API", enable_url: "https://console.cloud.google.com/apis/library/youtube.googleapis.com"}
      },
      %{
        id:           "photos",
        display_name: "Photos",
        description:  "Search + read the user's Google Photos library.",
        status:       :planned,
        scopes:       ["https://www.googleapis.com/auth/photoslibrary.readonly"],
        functions:    [],
        vendor_prereq: %{label: "Photos Library API", enable_url: "https://console.cloud.google.com/apis/library/photoslibrary.googleapis.com"}
      },
      %{
        id:           "keep",
        display_name: "Keep",
        description:  "Read + create Google Keep notes.",
        status:       :planned,
        scopes:       ["https://www.googleapis.com/auth/keep"],
        functions:    [],
        vendor_prereq: %{label: "Google Keep API", enable_url: "https://developers.google.com/keep/api"}
      },
      %{
        id:           "classroom",
        display_name: "Classroom",
        description:  "Read Google Classroom courses + assignments (education tenants).",
        status:       :planned,
        scopes:       ["https://www.googleapis.com/auth/classroom.courses.readonly"],
        functions:    [],
        vendor_prereq: %{label: "Google Classroom API", enable_url: "https://console.cloud.google.com/apis/library/classroom.googleapis.com"}
      },
      %{
        id:           "drive",
        display_name: "Drive",
        description:  "List Drive files and upload new ones.",
        scopes: [
          "https://www.googleapis.com/auth/drive.readonly",
          "https://www.googleapis.com/auth/drive.file"
        ],
        functions: ["drive.list", "drive.upload"],
        vendor_prereq: %{
          label:      "Drive API",
          enable_url: "https://console.cloud.google.com/apis/library/drive.googleapis.com"
        }
      }
    ]
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
  REST function handler. Returns the module that exposes
  `handler/0` (the `slug` + `functions` map the server registers). The
  `MCPServer` boot path enumerates every connector exposing this
  callback; no central list to update when a connector is added.
  """
  def mcp_handler_module, do: DmhAi.Connectors.GoogleWorkspace.MCPHandler
end
