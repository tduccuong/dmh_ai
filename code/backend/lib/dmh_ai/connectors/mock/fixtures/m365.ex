# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.M365 do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Microsoft 365 connector
  functions.

  Same shape contract as the GoogleWorkspace fixtures: each value
  is a map (or 1-arg function) returning the JSON-decoded payload
  the MCP server would put inside its `content[].text` envelope.

  Sentinel identifiers (German fake personas, fake message IDs)
  let runbooks + tests assert mechanically that the chain's
  output came from the connector path and not from the model
  inventing similar-sounding strings.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "mail.search"         => &mail_search/1,
      "mail.send"           => &mail_send/1,
      "mail.reply"          => &mail_reply/1,
      "mail.read"           => &mail_read/1,
      "mail.move_to_folder" => &mail_move_to_folder/1,
      "cal.find_free_slots" => &cal_find_free_slots/1,
      "cal.create_event"    => &cal_create_event/1,
      "cal.update_event"    => &cal_update_event/1,
      "cal.list_events"     => &cal_list_events/1,
      "files.list"          => &files_list/1,
      "files.upload"        => &files_upload/1,
      "files.download"      => &files_download/1,
      "teams.create_meeting"        => &teams_create_meeting/1,
      "teams.list_channels"         => &teams_list_channels/1,
      "teams.post_channel_message"  => &teams_post_channel_message/1,
      "todo.list"     => &todo_list/1,
      "todo.create"   => &todo_create/1,
      "todo.complete" => &todo_complete/1,
      "contacts.search" => &contacts_search/1,
      "excel.read_range"  => &excel_read_range/1,
      "excel.update_range" => &excel_update_range/1,
      "onenote.read_page" => &onenote_read_page/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture. Tests + runbooks assert
  these appear in the final model reply.
  """
  def sentinels do
    %{
      anna_email:      "anna.beispiel@dmh-m365-demo.example",
      stefan_email:    "stefan.beispiel@dmh-m365-demo.example",
      free_slot:       "2026-05-22T10:00:00Z",
      event_id:        "evt_m365_mock_demo_001",
      list_event_id:   "MOCKEVT001",
      list_event_subject: "Q2 Review — DMH Pilot Synchronisation",
      onedrive_file:   "Projektbrief_DMH_M365_Pilot_2026q2.docx",
      onedrive_folder: "M365 Pilot Handovers",
      teams_join_url:  "https://teams.microsoft.com/l/meetup-join/dmh-m365-mock",
      teams_meeting_id: "meeting_m365_mock_001",
      todo_title:      "Q2 review — finalise budget",
      todo_id:         "task_m365_mock_q2_review_001",
      contact_name:    "Maria Kontaktbeispiel",
      contact_email:   "maria.kontaktbeispiel@dmh-m365-demo.example",
      excel_value:     "M365-DEMO-CELL-SENTINEL",
      message_id:      "MOCKMSG001",
      channel_id:      "19:MOCKCHANNEL001@thread.tacv2",
      channel_name:    "Allgemein — DMH Pilot",
      team_id:         "MOCKTEAM001",
      task_id:         "MOCKTASK001",
      file_id:         "MOCK_FILE_001",
      file_download_text: "DMH M365 Pilot — interne Notiz. Sentinel: M365-DOWNLOAD-OK.",
      message_body:    "Sehr geehrtes Pilot-Team, anbei die Q2-Unterlagen zur Vorbereitung. Sentinel: M365-MAIL-READ-OK.",
      destination_folder_id: "archive"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp mail_search(args) do
    %{anna_email: anna, stefan_email: stefan} = sentinels()
    query = Map.get(args, "query", "")

    %{
      "messages" => [
        %{
          "id"          => "msg_m365_mock_1",
          "from"        => anna,
          "subject"     => "Outlook Pilot — Onboarding Plan",
          "snippet"     => "Hallo, anbei der Onboarding-Plan für den M365-Pilot.",
          "received_at" => "2026-05-15T08:24:00Z"
        },
        %{
          "id"          => "msg_m365_mock_2",
          "from"        => stefan,
          "subject"     => "Re: Q2 Reporting — Termin vorschlagen",
          "snippet"     => "Können wir nächste Woche einen Termin für das Reporting finden?",
          "received_at" => "2026-05-15T07:55:00Z"
        }
      ],
      "queried" => query
    }
  end

  defp mail_send(_args) do
    %{"accepted" => true}
  end

  defp cal_find_free_slots(args) do
    %{free_slot: slot} = sentinels()
    duration = Map.get(args, "duration_min", 30)

    %{
      "slots" => [
        %{
          "start"        => slot,
          "end"          => shift_iso(slot, duration),
          "duration_min" => duration
        }
      ]
    }
  end

  defp cal_create_event(args) do
    %{event_id: id} = sentinels()

    %{
      "event_id" => id,
      "title"    => Map.get(args, "title"),
      "start"    => Map.get(args, "start"),
      "end"      => Map.get(args, "end"),
      "web_link" => "https://outlook.office.com/calendar/item/" <> id
    }
  end

  defp files_list(_args) do
    %{onedrive_file: file, onedrive_folder: folder} = sentinels()

    %{
      "items" => [
        %{
          "id"            => "drv_m365_mock_1",
          "name"          => file,
          "kind"          => "file",
          "size"          => 28_410,
          "last_modified" => "2026-05-14T16:30:00Z"
        },
        %{
          "id"            => "drv_m365_mock_folder_1",
          "name"          => folder,
          "kind"          => "folder",
          "size"          => nil,
          "last_modified" => "2026-05-13T11:10:00Z"
        }
      ]
    }
  end

  defp files_upload(args) do
    %{
      "file_id" => "drv_m365_mock_uploaded_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "name"    => Map.get(args, "name"),
      "web_url" => "https://contoso-my.sharepoint.com/personal/demo/Documents/" <> Map.get(args, "name", "file")
    }
  end

  defp teams_create_meeting(args) do
    %{teams_join_url: url, teams_meeting_id: id} = sentinels()

    %{
      "join_url"   => url,
      "meeting_id" => id,
      "subject"    => Map.get(args, "subject", "Ad-hoc meeting")
    }
  end

  defp todo_list(_args) do
    %{todo_title: title, todo_id: id} = sentinels()

    %{
      "tasks" => [
        %{
          "id"     => id,
          "title"  => title,
          "notes"  => "Quarterly budget review prep — finalise figures.",
          "due"    => "2026-06-30T17:00:00Z",
          "status" => "notStarted"
        }
      ]
    }
  end

  defp todo_create(args) do
    %{
      "task_id" => "task_m365_mock_created_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "title"   => Map.get(args, "title")
    }
  end

  defp contacts_search(_args) do
    %{contact_name: name, contact_email: email} = sentinels()

    %{
      "contacts" => [
        %{"name" => name, "email" => email}
      ]
    }
  end

  defp excel_read_range(args) do
    %{excel_value: sentinel} = sentinels()

    %{
      "workbook_id" => Map.get(args, "workbook_id"),
      "worksheet"   => Map.get(args, "worksheet"),
      "range"       => Map.get(args, "range"),
      "values"      => [
        ["Header A", "Header B"],
        ["Row 1 A", sentinel]
      ]
    }
  end

  defp shift_iso(iso, minutes) when is_binary(iso) and is_integer(minutes) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        dt
        |> DateTime.add(minutes * 60, :second)
        |> DateTime.to_iso8601()

      _ ->
        iso
    end
  end

  # ── Per-function fixtures: new in slice 3 expansion ──────────────────

  defp mail_reply(args) do
    %{
      "ok"         => true,
      "message_id" => Map.get(args, "message_id")
    }
  end

  defp cal_update_event(args) do
    %{
      "event_id" => Map.get(args, "event_id"),
      "updated"  => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp onenote_read_page(_args) do
    %{
      "title" => "Sprint planning — week 22 (mock)",
      "text"  =>
        "Goals for the week:\n" <>
        "• Ship Calendly connector + Slice 3 expansion across HubSpot / GW / M365.\n" <>
        "• Verify cross-connector flow (HubSpot find → Calendly book → HubSpot log + task)."
    }
  end

  # ── Per-function fixtures: new in M365 +8 expansion ──────────────────

  defp cal_list_events(args) do
    %{
      list_event_id: id,
      list_event_subject: subject,
      anna_email: organiser,
      free_slot: free_slot
    } = sentinels()

    %{
      "events" => [
        %{
          "id"        => id,
          "subject"   => subject,
          "start"     => free_slot,
          "end"       => shift_iso(free_slot, 60),
          "location"  => "Teams · DMH Pilot",
          "organizer" => organiser,
          "web_link"  => "https://outlook.office.com/calendar/item/" <> id
        }
      ],
      "queried"  => Map.get(args, "query"),
      "time_min" => Map.get(args, "time_min"),
      "time_max" => Map.get(args, "time_max")
    }
  end

  defp mail_read(args) do
    %{
      anna_email: from,
      stefan_email: to,
      message_body: body,
      message_id: sentinel_id
    } = sentinels()

    id = Map.get(args, "message_id") || sentinel_id

    %{
      "message" => %{
        "id"              => id,
        "subject"         => "Outlook Pilot — Onboarding Plan",
        "from"            => from,
        "to"              => [to],
        "received_at"     => "2026-05-15T08:24:00Z",
        "body"            => body,
        "body_type"       => "text",
        "snippet"         => String.slice(body, 0, 64),
        "has_attachments" => false,
        "attachments"     => []
      }
    }
  end

  defp mail_move_to_folder(args) do
    %{message_id: sentinel_id} = sentinels()

    %{
      "message_id" => Map.get(args, "message_id") || sentinel_id
    }
  end

  defp excel_update_range(_args) do
    %{
      "ok" => true
    }
  end

  defp files_download(_args) do
    %{file_download_text: text} = sentinels()

    %{
      "content"      => text,
      "content_type" => "text/plain"
    }
  end

  defp teams_list_channels(_args) do
    %{channel_id: id, channel_name: name} = sentinels()

    %{
      "channels" => [
        %{
          "id"              => id,
          "name"            => name,
          "description"     => "Hauptkanal für den DMH M365-Pilot.",
          "membership_type" => "standard"
        }
      ]
    }
  end

  defp teams_post_channel_message(_args) do
    %{message_id: id} = sentinels()

    %{
      "message_id" => id
    }
  end

  defp todo_complete(args) do
    %{task_id: sentinel_id} = sentinels()

    %{
      "task_id" => Map.get(args, "task_id") || sentinel_id
    }
  end
end
