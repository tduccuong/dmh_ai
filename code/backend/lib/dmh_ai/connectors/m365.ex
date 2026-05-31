# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365 do
  @moduledoc """
  Microsoft 365 connector (Universal Region, Case B — Microsoft
  Graph API via the in-process MCPServer REST translator).

  Six functions at the SME-relevant Graph slice:

    mail.search           [read]   list / search Outlook messages
    mail.send             [write]  send an Outlook message
    cal.find_free_slots   [read]   availability lookup (getSchedule)
    cal.create_event      [write]  create an Outlook event
    files.list            [read]   list OneDrive items (root or path)
    files.upload          [write]  upload a OneDrive file (raw PUT)

  All endpoints hit `https://graph.microsoft.com/v1.0/me/...` with
  the user's Microsoft Identity Platform bearer. Three capability
  groups (mail, calendar, files) so admins can scope per-org via
  External Connectors; user OAuth consent screen only requests the
  scopes for ticked capabilities (Layer 1), the tool catalog hides
  unticked-capability functions (Layer 2), the dispatcher refuses
  them at call time (Layer 3).

  ## Vendor quirks (`remap_error/1`)

  Microsoft Graph wraps errors as
  `{"error": {"code": "<CamelCase>", "message": "..."}}`. The
  high-frequency cases an SME hits:

    * `RateLimited` (often with `Retry-After`) → `:rate_limited`.
    * `ItemNotFound` / `Request_ResourceNotFound` → `:not_found`.
    * `InvalidAuthenticationToken` → `:unauthorised`.
    * `AuthorizationFailed` → `:unauthorised`.
    * `NameAlreadyExists` (folder/file conflict) → `:duplicate`.

  Anything not in the table falls through to `:passthrough` so the
  generic `ErrorMap.classify/2` handles the long tail (incl. 403
  "API not enabled" / consent issues which become `:api_disabled`
  with actionable hint URLs).

  Layer B (`discover_metadata/1` + `inspect_property/3`) lives in
  `__MODULE__.LayerB` — this module is at the file-size ceiling and
  delegates those two callbacks rather than carrying their bodies
  inline.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(token),
    do: DmhAi.OAuth.Identity.OIDC.fetch(token,
          "https://graph.microsoft.com/oidc/userinfo", "email")

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://learn.microsoft.com/graph/overview",          title: "Microsoft Graph overview"},
       %{url: "https://learn.microsoft.com/graph/api/resources/mail-api-overview", title: "Outlook Mail (Graph)"},
       %{url: "https://learn.microsoft.com/graph/api/resources/calendar", title: "Outlook Calendar (Graph)"},
       %{url: "https://learn.microsoft.com/graph/api/resources/onedrive", title: "OneDrive (Graph)"},
       %{url: "https://learn.microsoft.com/graph/api/resources/onlinemeeting-api-overview", title: "Teams meetings"},
       %{url: "https://learn.microsoft.com/graph/api/resources/todo-overview", title: "Microsoft To Do"},
       %{url: "https://learn.microsoft.com/graph/api/resources/excel", title: "Excel via Graph"}
     ]}
  end

  @impl true
  def mcp_slug, do: "m365"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  defdelegate discover_metadata(user_id), to: __MODULE__.LayerB

  @impl true
  defdelegate inspect_property(function_name, path, ctx), to: __MODULE__.LayerB

  @impl true
  def manifest do
    %Manifest{
      connector: "m365",
      region:    "universal",
      functions: %{
        # vendor: GET /v1.0/me/messages  (KQL $search, $top, $select)
        "mail.search" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string, required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{messages: :list},
          scopes:  ["Mail.Read"]
        },

        # vendor: POST /v1.0/me/sendMail   (immediate send, no draft)
        "mail.send" => %Function{
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
          returns: %{accepted: :boolean},
          errors:  [:unauthorised, :rate_limited, :upstream_5xx],
          scopes:  ["Mail.Send"]
        },

        # vendor: POST /v1.0/me/calendar/getSchedule  (BUSY intervals)
        # shim computes free slots client-side (same shape as Google
        # Calendar freebusy + slot computation).
        "cal.find_free_slots" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "duration_min" => %{type: :integer, required: true,
                                provenance: %{kind: :literal_default, value: 30}},
            "between_from" => %{type: :string,  required: true,
                                provenance: %{kind: :literal_default}},
            "between_to"   => %{type: :string,  required: true,
                                provenance: %{kind: :literal_default}},
            "attendees"    => %{type: :list,    required: false}
          },
          returns: %{slots: :list},
          scopes:  ["Calendars.Read"]
        },

        # vendor: POST /v1.0/me/events     (immediate create)
        "cal.create_event" => %Function{
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
          returns: %{event_id: :string, web_link: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["Calendars.ReadWrite"]
        },

        # vendor: GET /v1.0/me/drive/root/children
        # vendor: GET /v1.0/me/drive/root:/<path>:/children
        "files.list" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "path"  => %{type: :string,  required: false},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{items: :list},
          scopes:  ["Files.Read"]
        },

        # vendor: PUT /v1.0/me/drive/root:/<filename>:/content
        # (raw upload, <4 MB; resumable session needed for larger files,
        # deferred — same content-size constraint as GW's drive.upload.)
        "files.upload" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"    => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}},
            "content" => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{file_id: :string, web_url: :string},
          errors:  [:unauthorised, :rate_limited, :duplicate],
          scopes:  ["Files.ReadWrite"]
        },

        # vendor: POST /v1.0/me/onlineMeetings
        # docs:   https://learn.microsoft.com/graph/api/application-post-onlinemeetings
        # shim translation: minimal body — `startDateTime` /
        # `endDateTime` (we default to now + 1h if absent) and
        # `subject`. Response carries `joinWebUrl` which is what
        # the model relays to the user.
        "teams.create_meeting" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "subject" => %{type: :string, required: false},
            "start"   => %{type: :string, required: false},
            "end"     => %{type: :string, required: false}
          },
          returns: %{join_url: :string, meeting_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["OnlineMeetings.ReadWrite"]
        },

        # vendor: GET  /v1.0/me/todo/lists/{list-id}/tasks
        # docs:   https://learn.microsoft.com/graph/api/todotasklist-list-tasks
        # shim translation: defaults to the user's "Tasks" list
        # (the default list). For now we ignore non-default lists;
        # multi-list support is a future polish.
        "todo.list" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{tasks: :list},
          scopes:  ["Tasks.Read"]
        },

        # vendor: POST /v1.0/me/todo/lists/{list-id}/tasks
        # docs:   https://learn.microsoft.com/graph/api/todotasklist-post-tasks
        "todo.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "title"     => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}},
            "body"      => %{type: :string, required: false},
            "due"       => %{type: :string, required: false}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["Tasks.ReadWrite"]
        },

        # vendor: GET /v1.0/me/contacts?$search="..."
        # docs:   https://learn.microsoft.com/graph/api/user-list-contacts
        # shim translation: $search (KQL) → response normalised to
        # `{name, email}` shape so the model gets the same record
        # type as GW's contacts.search.
        "contacts.search" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string, required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{contacts: :list},
          scopes:  ["Contacts.Read"]
        },

        # vendor: GET /v1.0/me/drive/items/{item-id}/workbook/worksheets/{sheet-name}/range(address='A1:C50')
        # docs:   https://learn.microsoft.com/graph/api/range-get
        # shim translation: `workbook_id` (Drive item id of the
        # xlsx file) + `worksheet` (sheet name or id) + `range`
        # (A1 notation) → response `values: [[...]]`. Read-only;
        # uses Files.Read scope.
        "excel.read_range" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "workbook_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "m365.files.list"}},
            # Outlook calls the default worksheet "Sheet1"; admins
            # rarely rename it, so this is the right default to try
            # without prompting.
            "worksheet"   => %{type: :string, required: true,
                               provenance: %{kind: :literal_default, value: "Sheet1"}},
            "range"       => %{type: :string, required: true,
                               provenance: %{kind: :literal_default, value: "A1:Z1000"}}
          },
          returns: %{values: :list},
          scopes:  ["Files.Read"]
        },

        # vendor: POST /me/messages/{id}/reply
        # Replies preserve the thread (Outlook calls it a "conversation")
        # automatically — the agent passes the original message_id and
        # Graph wires the In-Reply-To headers itself.
        "mail.reply" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "message_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "m365.mail.search"}},
            "body"       => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["Mail.Send"]
        },

        # vendor: PATCH /me/events/{id}
        # Reschedule / rename / move an existing calendar event.
        "cal.update_event" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            # No event-list verb in this connector yet — operators
            # paste the event id directly or it arrives as a
            # trigger payload.
            "event_id" => %{type: :string, required: true,
                            provenance: %{kind: :literal_default}},
            "patch"    => %{type: :map,    required: true,
                            provenance: %{kind: :literal_default}}
          },
          returns: %{event_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["Calendars.ReadWrite"]
        },

        # vendor: GET /me/onenote/pages/{id}/content
        # Returns the HTML content of a OneNote page. The shim
        # extracts plain text from <p>/<h*> blocks for the agent.
        "onenote.read_page" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            # OneNote page lookup is currently out-of-band (admin
            # supplies page id from a OneNote URL).
            "page_id" => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{text: :string, title: :string},
          scopes:  ["Notes.Read"]
        },

        # vendor: GET /me/calendar/calendarView?startDateTime=…&endDateTime=…
        # docs:   https://learn.microsoft.com/graph/api/calendar-list-calendarview
        # Returns the upcoming events between two ISO-8601 instants;
        # supports a free-text $search filter when `query` is set.
        "cal.list_events" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "time_min" => %{type: :string,  required: true,
                            provenance: %{kind: :literal_default}},
            "time_max" => %{type: :string,  required: true,
                            provenance: %{kind: :literal_default}},
            "query"    => %{type: :string,  required: false},
            "limit"    => %{type: :integer, required: false}
          },
          returns: %{events: :list},
          scopes:  ["Calendars.Read"]
        },

        # vendor: GET /me/messages/{id}
        # docs:   https://learn.microsoft.com/graph/api/message-get
        # Full body + attachments metadata for a single message id
        # (typically resolved via `mail.search` first).
        "mail.read" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "message_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "m365.mail.search"}}
          },
          returns: %{message: :map},
          scopes:  ["Mail.Read"]
        },

        # vendor: POST /me/messages/{id}/move
        # docs:   https://learn.microsoft.com/graph/api/message-move
        # Well-known destination ids:
        #   inbox · archive · deleteditems · drafts · sentitems · junkemail
        # Mailbox-local folder ids work too.
        "mail.move_to_folder" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "message_id"           => %{type: :string, required: true,
                                        provenance: %{kind: :lookup,
                                                      source: "m365.mail.search"}},
            "destination_folder_id" => %{type: :string, required: true,
                                         provenance: %{kind: :from_user}}
          },
          returns: %{message_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["Mail.ReadWrite"]
        },

        # vendor: PATCH /me/drive/items/{id}/workbook/worksheets/{name}/range(address='A1:C5')
        # docs:   https://learn.microsoft.com/graph/api/range-update
        # Writes a 2D `values` array into a worksheet cell range
        # (A1 notation). Range string is regex-validated server-side
        # before the URL is built.
        "excel.update_range" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "file_id"   => %{type: :string, required: true,
                             provenance: %{kind: :lookup,
                                           source: "m365.files.list"}},
            "worksheet" => %{type: :string, required: true,
                             provenance: %{kind: :from_user}},
            "range"     => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}},
            "values"    => %{type: :list,   required: true,
                             provenance: %{kind: :literal_default}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["Files.ReadWrite"]
        },

        # vendor: GET /me/drive/items/{id}/content
        # docs:   https://learn.microsoft.com/graph/api/driveitem-get-content
        # text/* responses pass through as a string; binary content
        # is base64-encoded so the model can still attach / reference
        # it through the standard string envelope.
        "files.download" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "file_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "m365.files.list"}}
          },
          returns: %{content: :string, content_type: :string},
          scopes:  ["Files.Read"]
        },

        # vendor: GET /teams/{team_id}/channels
        # docs:   https://learn.microsoft.com/graph/api/channel-list
        # Lists the channels of a Team (team id is the AAD group id).
        "teams.list_channels" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "team_id" => %{type: :string,  required: true,
                           provenance: %{kind: :from_user}},
            "limit"   => %{type: :integer, required: false}
          },
          returns: %{channels: :list},
          scopes:  ["Channel.ReadBasic.All"]
        },

        # vendor: POST /teams/{team_id}/channels/{channel_id}/messages
        # docs:   https://learn.microsoft.com/graph/api/chatmessage-post
        # Channel ids take the shape `19:<base64>@thread.tacv2`; both
        # ids whitelist `[A-Za-z0-9_=:-]+` so they pass `safe_path_id`.
        "teams.post_channel_message" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "team_id"    => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "channel_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "m365.teams.list_channels"}},
            "body"       => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "subject"    => %{type: :string, required: false}
          },
          returns: %{message_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["ChannelMessage.Send"]
        },

        # vendor: PATCH /me/todo/lists/{list_id}/tasks/{task_id}
        # docs:   https://learn.microsoft.com/graph/api/todotask-update
        # Marks a Microsoft To Do task as completed by setting its
        # `status` field — Graph derives `completedDateTime` from it.
        "todo.complete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "list_id" => %{type: :string, required: true,
                           provenance: %{kind: :from_user}},
            "task_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "m365.todo.list"}}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["Tasks.ReadWrite"]
        }
      }
    }
  end

  @impl true
  # Primitive 0.9 — no /users?$filter=mail-eq function in this
  # manifest yet, so workflows can't resolve `@user_N` against
  # M365 directly. Fix: add `users.find_by_email` (GET
  # /users?$filter=mail eq '<email>') and switch this to:
  #   %{function: "m365.users.find_by_email",
  #     by_arg: :email, emit_field: "id"}
  def identity_lookup, do: nil

  @impl true
  def remap_error(%{"error" => %{"code" => code}}) do
    case code do
      "RateLimited"                  -> :rate_limited
      "ItemNotFound"                 -> :not_found
      "Request_ResourceNotFound"     -> :not_found
      "InvalidAuthenticationToken"   -> :unauthorised
      "AuthorizationFailed"          -> :unauthorised
      "NameAlreadyExists"            -> :duplicate
      _                              -> :passthrough
    end
  end

  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error(_), do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Microsoft Identity
  Platform's v2 endpoints under `login.microsoftonline.com/common`
  (multi-tenant default — admin can override to a single-tenant
  ID via the FE if they want).

  `offline_access` in the scope set is what makes Microsoft issue
  a refresh_token; without it the access_token expires in an hour
  and the user has to re-Connect. `prompt=consent` forces the
  consent screen on every grant so refresh_token issuance stays
  reliable (mirrors Google's quirk).
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "m365",
      display_name:           "Microsoft 365",
      host_match:             "login.microsoftonline.com",
      authorization_endpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token_endpoint:         "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      scopes: [
        "Mail.Read",
        "Mail.ReadWrite",
        "Mail.Send",
        "Calendars.Read",
        "Calendars.ReadWrite",
        "Files.Read",
        "Files.ReadWrite",
        "OnlineMeetings.ReadWrite",
        "Tasks.Read",
        "Tasks.ReadWrite",
        "Contacts.Read",
        "Channel.ReadBasic.All",
        "ChannelMessage.Send",
        "offline_access",
        "User.Read"
      ],
      # Identity capture lives in `fetch_userinfo/1` (see top of module).
      userinfo_endpoint:      nil,
      userinfo_field_path:    nil,
      extra_auth_params:      %{"prompt" => "consent"}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. The `mcp_url` is
  operator-set via External Connectors; defaults are pre-filled
  via `default_mcp_url/0` (the in-process MCPServer URL).
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "m365",
      name:        "Microsoft 365",
      description: "Outlook mail, calendar, and OneDrive files via the Microsoft Graph API",
      auth_kind:   :oauth,
      categories:  ["productivity", "email", "calendar", "storage"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers in the fixture (German
  fake personas, fake message IDs) so the chain's contribution is
  mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_m365",
      port_env:     "DMH_AI_M365_MOCK_PORT",
      default_port: 8088,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.M365.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the M365 MCP as an in-process REST translator at
  `http://127.0.0.1:<DMH_AI_REAL_MCP_PORT>/m365`. The FE pre-fills
  the External Connectors form's MCP URL field with this value so
  the admin doesn't have to know the deployment-internal URL.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/m365"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount M365 on the shared
  in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.M365.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. The
  three enforcement layers (OAuth scope filter, tool catalog
  filter, dispatcher gate) all read from `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "mail",
        display_name: "Outlook Mail",
        description:  "Read inbox messages, send mail, and organise messages on the user's behalf.",
        scopes:       ["Mail.Read", "Mail.ReadWrite", "Mail.Send"],
        functions:    ["mail.search", "mail.read", "mail.send", "mail.reply", "mail.move_to_folder"],
        vendor_prereq: %{
          label:      "Microsoft Graph (Mail permissions)",
          enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
        }
      },
      %{
        id:           "calendar",
        display_name: "Outlook Calendar",
        description:  "Read availability, list upcoming events, and create / update calendar events.",
        scopes:       ["Calendars.Read", "Calendars.ReadWrite"],
        functions:    ["cal.find_free_slots", "cal.list_events", "cal.create_event", "cal.update_event"],
        vendor_prereq: %{
          label:      "Microsoft Graph (Calendar permissions)",
          enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
        }
      },
      %{
        id:           "files",
        display_name: "OneDrive Files",
        description:  "List OneDrive files, download contents, and upload new ones.",
        scopes:       ["Files.Read", "Files.ReadWrite"],
        functions:    ["files.list", "files.download", "files.upload"],
        vendor_prereq: %{
          label:      "Microsoft Graph (Files permissions)",
          enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
        }
      },
      %{
        id:           "teams",
        display_name: "Teams",
        description:  "Create Teams meetings, list channels, and post messages to channels.",
        scopes:       ["OnlineMeetings.ReadWrite", "Channel.ReadBasic.All", "ChannelMessage.Send"],
        functions:    ["teams.create_meeting", "teams.list_channels", "teams.post_channel_message"],
        vendor_prereq: %{
          label:      "Microsoft Graph (Teams meetings, channels, and channel messages)",
          enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
        }
      },
      %{
        id:           "todo",
        display_name: "Microsoft To Do",
        description:  "List the user's To Do tasks on their default list, add new ones, and mark them complete.",
        scopes:       ["Tasks.Read", "Tasks.ReadWrite"],
        functions:    ["todo.list", "todo.create", "todo.complete"],
        vendor_prereq: %{
          label:      "Microsoft Graph (Tasks delegated permissions)",
          enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
        }
      },
      %{
        id:           "contacts",
        display_name: "Contacts",
        description:  "Search the user's Outlook contacts to resolve names to email addresses.",
        scopes:       ["Contacts.Read"],
        functions:    ["contacts.search"],
        vendor_prereq: %{
          label:      "Microsoft Graph (Contacts.Read delegated permission)",
          enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
        }
      },
      %{
        id:           "excel",
        display_name: "Excel",
        description:  "Read and update cell ranges in Excel workbooks stored in OneDrive.",
        scopes:       ["Files.Read", "Files.ReadWrite"],
        functions:    ["excel.read_range", "excel.update_range"],
        vendor_prereq: %{
          label:      "Microsoft Graph (Files permissions cover workbook reads + writes)",
          enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
        }
      },
      # ── Planned (vendor surface visible to admins, not yet built) ──
      %{
        id:           "teams_chat",
        display_name: "Teams 1:1 / Group Chat",
        description:  "Read + send Teams 1:1 and group chat history (channel messages already live under the Teams capability).",
        status:       :planned,
        scopes:       ["Chat.ReadWrite"],
        functions:    [],
        vendor_prereq: %{label: "Microsoft Graph (Teams chat permissions)",
                         enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"}
      },
      %{
        id:           "onenote",
        display_name: "OneNote",
        description:  "Read OneNote pages as plain text (for summarization, extraction).",
        scopes:       ["Notes.Read"],
        functions:    ["onenote.read_page"],
        vendor_prereq: %{label: "Microsoft Graph (Notes.Read)",
                         enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"}
      },
      %{
        id:           "planner",
        display_name: "Planner",
        description:  "Read + create tasks in Microsoft Planner boards.",
        status:       :planned,
        scopes:       ["Tasks.ReadWrite", "Group.Read.All"],
        functions:    [],
        vendor_prereq: %{label: "Microsoft Graph (Planner via Tasks + Groups)",
                         enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"}
      },
      %{
        id:           "sharepoint",
        display_name: "SharePoint",
        description:  "Read SharePoint sites, lists, and document libraries.",
        status:       :planned,
        scopes:       ["Sites.Read.All"],
        functions:    [],
        vendor_prereq: %{label: "Microsoft Graph (Sites.Read.All)",
                         enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"}
      },
      %{
        id:           "bookings",
        display_name: "Bookings",
        description:  "Read + create appointments in Microsoft Bookings.",
        status:       :planned,
        scopes:       ["Bookings.ReadWrite.All"],
        functions:    [],
        vendor_prereq: %{label: "Microsoft Graph (Bookings)",
                         enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"}
      },
      %{
        id:           "ms_forms",
        display_name: "Forms",
        description:  "Read Microsoft Forms responses.",
        status:       :planned,
        scopes:       ["Forms.Read"],
        functions:    [],
        vendor_prereq: %{label: "Microsoft Graph (Forms)",
                         enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"}
      },
      %{
        id:           "powerbi",
        display_name: "Power BI",
        description:  "Read Power BI dashboards + report metadata.",
        status:       :planned,
        scopes:       ["https://analysis.windows.net/powerbi/api/Dataset.Read.All"],
        functions:    [],
        vendor_prereq: %{label: "Power BI API",
                         enable_url: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"}
      }
    ]
  end
end
