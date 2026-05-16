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
      "cal.find_free_slots" => &cal_find_free_slots/1,
      "cal.create_event"    => &cal_create_event/1,
      "files.list"          => &files_list/1,
      "files.upload"        => &files_upload/1,
      "teams.create_meeting" => &teams_create_meeting/1,
      "todo.list"   => &todo_list/1,
      "todo.create" => &todo_create/1,
      "contacts.search" => &contacts_search/1,
      "excel.read_range" => &excel_read_range/1
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
      onedrive_file:   "Projektbrief_DMH_M365_Pilot_2026q2.docx",
      onedrive_folder: "M365 Pilot Handovers",
      teams_join_url:  "https://teams.microsoft.com/l/meetup-join/dmh-m365-mock",
      teams_meeting_id: "meeting_m365_mock_001",
      todo_title:      "Q2 review — finalise budget",
      todo_id:         "task_m365_mock_q2_review_001",
      contact_name:    "Maria Kontaktbeispiel",
      contact_email:   "maria.kontaktbeispiel@dmh-m365-demo.example",
      excel_value:     "M365-DEMO-CELL-SENTINEL"
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
end
