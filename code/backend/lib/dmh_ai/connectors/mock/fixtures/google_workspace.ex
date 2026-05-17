# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.GoogleWorkspace do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Google Workspace connector
  functions.

  Every response value is a map (or 1-arg function) returning the
  shape `Connectors.MCPAdapter.Caller.normalize_mcp_result/1`
  expects — i.e. the JSON-decoded payload the MCP server would
  return inside its `content[].text` envelope.

  Identifiers in here are deliberately unique strings (synthetic
  email addresses, fixture-only event IDs) so a runbook or test
  can assert *"if this string reached the model, the indexed
  context block contained the mock response"* — analogous to the
  '28 Tage' / 'dmh-prod-sev1' / 'urn:dmh-sme-demo:saml' proof
  points in the 0.2 demos.
  """

  @doc """
  The fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "gmail.search" => &gmail_search/1,
      "gmail.send"   => &gmail_send/1,
      "gmail.reply"  => &gmail_reply/1,
      "gcal.find_free_slots" => &gcal_find_free_slots/1,
      "gcal.create_event"    => &gcal_create_event/1,
      "gcal.update_event"    => &gcal_update_event/1,
      "drive.list"   => &drive_list/1,
      "drive.upload" => &drive_upload/1,
      "docs.read_text" => &docs_read_text/1,
      "meet.create_meeting" => &meet_create_meeting/1,
      "tasks.list"   => &tasks_list/1,
      "tasks.create" => &tasks_create/1,
      "contacts.search" => &contacts_search/1,
      "sheets.read_range" => &sheets_read_range/1
    }
  end

  # ── Fixture identifiers (the strings the runbook / tests assert on) ───

  @doc """
  Sentinel strings unique to this fixture. Tests + runbooks assert
  these appear in the final model reply — that's the proof the
  indexed-context block reached the model rather than the model
  inventing similar-sounding output.
  """
  def sentinels do
    %{
      nina_email:      "nina.beispiel@dmh-demo.example",
      tobias_email:    "tobias.beispiel@dmh-demo.example",
      free_slot:       "2026-05-21T14:30:00+02:00",
      event_id:        "evt_mock_dmh_demo_001",
      drive_file:      "spec_dmh_demo_handover_2026q2.md",
      drive_folder_id: "drv_folder_mock_handovers",
      meet_join_url:   "https://meet.google.com/dmh-demo-mock",
      meet_code:       "dmh-demo-mock",
      task_title:      "Q2 Tax filing — collect receipts",
      task_id:         "task_gw_mock_demo_q2_001",
      contact_name:    "Petra Kontaktbeispiel",
      contact_email:   "petra.kontaktbeispiel@dmh-demo.example",
      sheet_value:     "DMH-DEMO-CELL-SENTINEL"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────────

  defp gmail_search(args) do
    %{nina_email: nina, tobias_email: tobias} = sentinels()
    # Honour the query arg loosely so a test can assert that the
    # arg DID reach the mock (the simplest "did the dispatcher
    # forward args?" check).
    query = Map.get(args, "query", "")

    %{
      "messages" => [
        %{
          "id"      => "msg_mock_1",
          "from"    => nina,
          "subject" => "Lieferanten-Update Q2",
          "snippet" => "Hallo, der Liefertermin verschiebt sich um eine Woche…",
          "received_at" => "2026-05-14T08:12:00+02:00"
        },
        %{
          "id"      => "msg_mock_2",
          "from"    => tobias,
          "subject" => "Re: Vertragsentwurf",
          "snippet" => "Anbei der überarbeitete Entwurf. Bitte bis Freitag prüfen.",
          "received_at" => "2026-05-14T07:48:00+02:00"
        }
      ],
      "queried" => query
    }
  end

  defp gmail_send(args) do
    %{
      "message_id"  => "msg_mock_sent_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "to"          => Map.get(args, "to"),
      "subject"     => Map.get(args, "subject"),
      "delivered_at" => "2026-05-14T09:00:00+02:00"
    }
  end

  defp gcal_find_free_slots(args) do
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

  defp gcal_create_event(args) do
    %{event_id: id} = sentinels()
    %{
      "event_id" => id,
      "title"    => Map.get(args, "title"),
      "start"    => Map.get(args, "start"),
      "end"      => Map.get(args, "end"),
      "html_link" => "https://calendar.google.com/calendar/event?eid=" <> id
    }
  end

  defp drive_list(_args) do
    %{drive_file: file, drive_folder_id: folder} = sentinels()
    %{
      "items" => [
        %{
          "id"       => "drv_mock_1",
          "name"     => file,
          "parent"   => folder,
          "mime_type" => "text/markdown",
          "size_bytes" => 14_232,
          "modified_at" => "2026-05-13T17:45:00+02:00"
        }
      ]
    }
  end

  defp drive_upload(args) do
    %{
      "file_id" => "drv_mock_uploaded_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "name"    => Map.get(args, "name"),
      "mime_type" => Map.get(args, "mime_type") || "application/octet-stream"
    }
  end

  defp meet_create_meeting(_args) do
    %{meet_join_url: url, meet_code: code} = sentinels()

    %{
      "join_url"     => url,
      "meeting_code" => code,
      "space_name"   => "spaces/" <> code
    }
  end

  defp tasks_list(_args) do
    %{task_title: title, task_id: id} = sentinels()

    %{
      "tasks" => [
        %{
          "id"     => id,
          "title"  => title,
          "notes"  => "Liste mit allen offenen Belegen für die Q2-Steuererklärung.",
          "due"    => "2026-06-30T00:00:00Z",
          "status" => "needsAction"
        }
      ]
    }
  end

  defp tasks_create(args) do
    %{
      "task_id" => "task_gw_mock_created_" <> Integer.to_string(:erlang.unique_integer([:positive])),
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

  defp sheets_read_range(args) do
    %{sheet_value: sentinel} = sentinels()

    %{
      "spreadsheet_id" => Map.get(args, "spreadsheet_id"),
      "range"          => Map.get(args, "range"),
      "values"         => [
        ["Header A", "Header B"],
        ["Row 1 A", sentinel]
      ]
    }
  end

  # Add `minutes` to an RFC-3339 timestamp string. Not a general
  # purpose ISO library — assumes timezone-suffixed RFC-3339 like
  # the fixture's `2026-05-21T14:30:00+02:00`. Good enough for
  # fixture math.
  defp shift_iso(iso, minutes) when is_binary(iso) and is_integer(minutes) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, offset} ->
        dt
        |> DateTime.add(minutes * 60, :second)
        |> DateTime.shift_zone!("Etc/UTC")
        |> DateTime.to_iso8601()
        |> shift_zone(offset)

      _ ->
        iso
    end
  end

  defp shift_zone(iso, _offset), do: iso

  # ── Per-function fixtures: new in slice 3 expansion ──────────────────

  defp gmail_reply(args) do
    %{
      "id"        => "mock_reply_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "threadId"  => Map.get(args, "thread_id") || "mock_thread_001"
    }
  end

  defp gcal_update_event(args) do
    %{
      "event_id" => Map.get(args, "event_id"),
      "updated"  => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp docs_read_text(_args) do
    %{
      "title" => "Quarterly product roadmap (mock)",
      "text"  =>
        "Q2 themes: shipping the SME connector ladder, deepening per-connector workflow primitives,\n" <>
        "and standing up the live-portal UAT runbooks. Q3 themes: webhook ingress + scheduled-action\n" <>
        "primitive, opening the door to multi-day autonomous flows."
    }
  end
end
