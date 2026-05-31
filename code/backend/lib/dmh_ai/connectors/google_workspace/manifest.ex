# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.Manifest do
  @moduledoc """
  The per-function manifest for the Google Workspace connector. Pulled
  out of the parent `GoogleWorkspace` module because the parent is at
  the file-size ceiling and re-exports `manifest/0` via `defdelegate`.

  Each function is grounded in a documented Google REST API endpoint
  (see the `# vendor:` / `# docs:` comments on each entry); the MCP
  server is a JSON-RPC translation layer over those endpoints.
  """

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @spec manifest() :: Manifest.t()
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

        # vendor: GET https://www.googleapis.com/calendar/v3/calendars/primary/events
        # docs:   https://developers.google.com/calendar/api/v3/reference/events/list
        # shim translation: manifest args `time_min` / `time_max` →
        # API args `timeMin` / `timeMax` (RFC-3339 strings); `query`
        # → `q` (free-text search across event fields); `max_results`
        # → `maxResults`. The shim always pins `singleEvents=true` +
        # `orderBy=startTime` so recurring events expand into their
        # instances and the response is chronological — what every
        # "list events between X and Y" caller wants.
        "gcal.list_events" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "time_min"    => %{type: :string,  required: true,
                               provenance: %{kind: :literal_default}},
            "time_max"    => %{type: :string,  required: true,
                               provenance: %{kind: :literal_default}},
            "query"       => %{type: :string,  required: false},
            "max_results" => %{type: :integer, required: false}
          },
          returns: %{events: :list},
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

        # vendor: GET /gmail/v1/users/me/messages/{message_id}?format=full
        # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/get
        # Returns the full message envelope — headers, body, snippet,
        # attachment metadata. The shim flattens common headers
        # (From / To / Subject / Date) so the model can quote them
        # without walking the `payload.headers[]` list.
        "gmail.read" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "message_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "google_workspace.gmail.search"}}
          },
          returns: %{message: :map},
          scopes:  ["https://www.googleapis.com/auth/gmail.readonly"]
        },

        # vendor: POST /gmail/v1/users/me/messages/{message_id}/modify
        # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/modify
        # body `{addLabelIds:[…], removeLabelIds:[…]}`. The handler
        # rejects requests where both lists are empty — the API would
        # accept the no-op, but it always indicates a model bug.
        "gmail.label" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "message_id"       => %{type: :string, required: true,
                                    provenance: %{kind: :lookup,
                                                  source: "google_workspace.gmail.search"}},
            "add_label_ids"    => %{type: :list,  required: false,
                                    provenance: %{kind: :literal_default}},
            "remove_label_ids" => %{type: :list,  required: false,
                                    provenance: %{kind: :literal_default}}
          },
          returns: %{message_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/gmail.modify"]
        },

        # vendor: POST /gmail/v1/users/me/drafts
        # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.drafts/create
        # The shim composes RFC-2822 MIME (plain text) and wraps it
        # inside `{"message": {"raw": "<base64url>"}}` — same encoder
        # used by `gmail.send`.
        "gmail.create_draft" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "to"      => %{type: :string, required: true, format: :email,
                           provenance: %{kind: :from_user}},
            "subject" => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}},
            "body"    => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{draft_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/gmail.compose"]
        },

        # vendor: POST /sheets/v4/spreadsheets/{id}/values/{range}:append
        # docs:   https://developers.google.com/sheets/api/reference/rest/v4/spreadsheets.values/append
        # The flat `values` list is wrapped into a single row so the
        # caller doesn't have to nest. `valueInputOption=USER_ENTERED`
        # so Sheets parses formulas / dates the way the spreadsheet UI
        # would.
        "sheets.append_row" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "spreadsheet_id" => %{type: :string, required: true,
                                  provenance: %{kind: :lookup,
                                                source: "google_workspace.drive.list"}},
            "range"          => %{type: :string, required: true,
                                  provenance: %{kind: :literal_default, value: "A1"}},
            "values"         => %{type: :list,   required: true,
                                  provenance: %{kind: :literal_default}}
          },
          returns: %{updated_range: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/spreadsheets"]
        },

        # vendor: PUT /sheets/v4/spreadsheets/{id}/values/{range}
        # docs:   https://developers.google.com/sheets/api/reference/rest/v4/spreadsheets.values/update
        # `values` is a 2-D array of rows — passed through verbatim.
        # `valueInputOption=USER_ENTERED` for the same reason as
        # `sheets.append_row`.
        "sheets.update_range" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "spreadsheet_id" => %{type: :string, required: true,
                                  provenance: %{kind: :lookup,
                                                source: "google_workspace.drive.list"}},
            "range"          => %{type: :string, required: true,
                                  provenance: %{kind: :literal_default}},
            "values"         => %{type: :list,   required: true,
                                  provenance: %{kind: :literal_default}}
          },
          returns: %{updated_range: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/spreadsheets"]
        },

        # vendor: GET /drive/v3/files/{file_id}?alt=media
        # docs:   https://developers.google.com/drive/api/reference/rest/v3/files/get
        # `text/*` content surfaces as a string; other MIME types are
        # base64-encoded so the model can still reference / forward the
        # bytes through a string envelope. Native Docs / Sheets / Slides
        # files (`application/vnd.google-apps.*`) require
        # `files/{id}/export?mimeType=…` instead — this verb covers
        # plain stored files only.
        "drive.download" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "file_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "google_workspace.drive.list"}}
          },
          returns: %{content: :string, content_type: :string},
          scopes:  ["https://www.googleapis.com/auth/drive.readonly"]
        },

        # vendor: POST /drive/v3/files
        # docs:   https://developers.google.com/drive/api/reference/rest/v3/files/create
        # body `{name, mimeType: "application/vnd.google-apps.folder",
        # parents: [parent_id]}`. `parent_id` is omitted (drive root)
        # when absent.
        "drive.create_folder" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"      => %{type: :string, required: true,
                             provenance: %{kind: :from_user}},
            "parent_id" => %{type: :string, required: false,
                             provenance: %{kind: :lookup,
                                           source: "google_workspace.drive.list"}}
          },
          returns: %{folder_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/drive.file"]
        },

        # vendor: DELETE /calendar/v3/calendars/{calendar_id}/events/{event_id}
        # docs:   https://developers.google.com/calendar/api/v3/reference/events/delete
        # Calendar id defaults to `primary` for the common single-user
        # case; pass an explicit id to delete from a shared / secondary
        # calendar.
        "gcal.delete_event" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "event_id"    => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "google_workspace.gcal.list_events"}},
            "calendar_id" => %{type: :string, required: false,
                               provenance: %{kind: :literal_default, value: "primary"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["https://www.googleapis.com/auth/calendar"]
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
        },

        # vendor: GET https://admin.googleapis.com/admin/directory/v1/users/{userKey}
        # docs:   https://developers.google.com/admin-sdk/directory/reference/rest/v1/users/get
        # Identity pivot — resolves an email (acts as `userKey`) to
        # the Directory user resource so workflows binding `@user_N`
        # can pick up the user's numeric `id` for downstream
        # assignment. The Directory API is admin-scoped — only a
        # Workspace admin can grant `admin.directory.user.readonly`.
        "directory.users.find_by_email" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string, required: true, format: :email,
                         provenance: %{kind: :from_user}}
          },
          returns: %{user: :map},
          scopes:  ["https://www.googleapis.com/auth/admin.directory.user.readonly"]
        }
      }
    }
  end
end
