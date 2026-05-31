# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.Capabilities do
  @moduledoc """
  Capability groups exposed by the Google Workspace connector. Pulled
  out of the parent `GoogleWorkspace` module because the parent is at
  the file-size ceiling and re-exports `capabilities/0` via
  `defdelegate`.

  Each group bundles:
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
        description:  "Read inbox messages, label/move them, draft replies, and send mail on the user's behalf.",
        scopes: [
          "https://www.googleapis.com/auth/gmail.readonly",
          "https://www.googleapis.com/auth/gmail.send",
          "https://www.googleapis.com/auth/gmail.modify",
          "https://www.googleapis.com/auth/gmail.compose"
        ],
        functions: ["gmail.search", "gmail.send", "gmail.reply",
                    "gmail.read", "gmail.label", "gmail.create_draft"],
        vendor_prereq: %{
          label:      "Gmail API",
          enable_url: "https://console.cloud.google.com/apis/library/gmail.googleapis.com"
        }
      },
      %{
        id:           "calendar",
        display_name: "Calendar",
        description:  "Read availability and create / update / delete calendar events.",
        scopes: [
          "https://www.googleapis.com/auth/calendar.readonly",
          "https://www.googleapis.com/auth/calendar.events",
          "https://www.googleapis.com/auth/calendar"
        ],
        functions: ["gcal.find_free_slots", "gcal.list_events",
                    "gcal.create_event", "gcal.update_event", "gcal.delete_event"],
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
        id:           "directory",
        display_name: "Directory — Users",
        description:  "Pivot a Workspace user by email to their Directory user id (identity lookup).",
        scopes:       ["https://www.googleapis.com/auth/admin.directory.user.readonly"],
        functions:    ["directory.users.find_by_email"],
        vendor_prereq: %{
          label:      "Admin SDK Directory API (admin.directory.user.readonly requires Workspace admin consent at install)",
          enable_url: "https://console.cloud.google.com/apis/library/admin.googleapis.com",
          help:       "admin.directory.user.readonly is an admin-consent scope. Only a Google Workspace admin can grant it; personal Gmail / @gmail.com accounts cannot. Without it, directory lookups return 401 even with a fresh token."
        }
      },
      %{
        id:           "sheets",
        display_name: "Sheets",
        description:  "Read cell ranges from the user's Google Sheets, and write rows / range updates back.",
        scopes: [
          "https://www.googleapis.com/auth/spreadsheets.readonly",
          "https://www.googleapis.com/auth/spreadsheets"
        ],
        functions: ["sheets.read_range", "sheets.append_row", "sheets.update_range"],
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
        description:  "List Drive files, download stored content, create folders, and upload new files.",
        scopes: [
          "https://www.googleapis.com/auth/drive.readonly",
          "https://www.googleapis.com/auth/drive.file"
        ],
        functions: ["drive.list", "drive.upload", "drive.download", "drive.create_folder"],
        vendor_prereq: %{
          label:      "Drive API",
          enable_url: "https://console.cloud.google.com/apis/library/drive.googleapis.com"
        }
      }
    ]
  end
end
