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
      "gmail.read"   => &gmail_read/1,
      "gmail.label"  => &gmail_label/1,
      "gmail.create_draft" => &gmail_create_draft/1,
      "gcal.find_free_slots" => &gcal_find_free_slots/1,
      "gcal.list_events"     => &gcal_list_events/1,
      "gcal.create_event"    => &gcal_create_event/1,
      "gcal.update_event"    => &gcal_update_event/1,
      "gcal.delete_event"    => &gcal_delete_event/1,
      "drive.list"   => &drive_list/1,
      "drive.upload" => &drive_upload/1,
      "drive.download" => &drive_download/1,
      "drive.create_folder" => &drive_create_folder/1,
      "docs.read_text" => &docs_read_text/1,
      "meet.create_meeting" => &meet_create_meeting/1,
      "tasks.list"   => &tasks_list/1,
      "tasks.create" => &tasks_create/1,
      "contacts.search" => &contacts_search/1,
      "sheets.read_range" => &sheets_read_range/1,
      "sheets.append_row" => &sheets_append_row/1,
      "sheets.update_range" => &sheets_update_range/1,
      "directory.users.find_by_email" => &directory_users_find_by_email/1
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
      listed_event_id: "evt_mock_dmh_demo_listed_001",
      drive_file:      "spec_dmh_demo_handover_2026q2.md",
      drive_folder_id: "drv_folder_mock_handovers",
      meet_join_url:   "https://meet.google.com/dmh-demo-mock",
      meet_code:       "dmh-demo-mock",
      task_title:      "Q2 Tax filing — collect receipts",
      task_id:         "task_gw_mock_demo_q2_001",
      contact_name:    "Petra Kontaktbeispiel",
      contact_email:   "petra.kontaktbeispiel@dmh-demo.example",
      sheet_value:     "DMH-DEMO-CELL-SENTINEL",
      gmail_msg_id:    "mock_msg_001",
      gmail_draft_id:  "mock_draft_001",
      drive_folder_new_id: "mock_folder_001",
      sheets_updated_range: "Sheet1!A1:B1",
      drive_download_body: "Aktenvermerk Q2 2026 — Stichprobe Belegprüfung."
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

  defp gcal_list_events(_args) do
    %{listed_event_id: lid} = sentinels()

    %{
      "events" => [
        %{
          "id"      => lid,
          "summary" => "Mock standup",
          "start"   => %{"dateTime" => "2026-05-26T09:00:00Z"},
          "end"     => %{"dateTime" => "2026-05-26T09:30:00Z"}
        },
        %{
          "id"      => "evt_mock_dmh_demo_listed_002",
          "summary" => "Mock review",
          "start"   => %{"dateTime" => "2026-05-27T14:00:00Z"},
          "end"     => %{"dateTime" => "2026-05-27T15:00:00Z"}
        }
      ]
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

  # ── Per-function fixtures: new in slice 4 expansion ──────────────────

  defp gmail_read(args) do
    %{gmail_msg_id: mid, nina_email: from} = sentinels()

    %{
      "message" => %{
        "id"          => Map.get(args, "message_id", mid),
        "thread_id"   => "mock_thread_001",
        "subject"     => "Angebot Lieferanten-Update Q2",
        "from"        => from,
        "to"          => "betrieb@dmh-demo.example",
        "received_at" => "2026-05-14T08:12:00+02:00",
        "snippet"     => "Hallo, der Liefertermin verschiebt sich um eine Woche…",
        "body"        =>
          "Hallo zusammen,\n\n" <>
          "der Liefertermin für die Q2-Charge verschiebt sich um eine Woche\n" <>
          "auf den 28. Mai. Bitte das Team entsprechend informieren.\n\n" <>
          "Viele Grüße,\nNina",
        "label_ids"   => ["INBOX", "IMPORTANT"],
        "attachments" => []
      }
    }
  end

  defp gmail_label(args) do
    %{gmail_msg_id: mid} = sentinels()

    %{
      "message_id"     => Map.get(args, "message_id", mid),
      "added_labels"   => Map.get(args, "add_label_ids") || [],
      "removed_labels" => Map.get(args, "remove_label_ids") || []
    }
  end

  defp gmail_create_draft(args) do
    %{gmail_draft_id: did} = sentinels()

    %{
      "draft_id"   => did,
      "message_id" => "mock_msg_draft_message_001",
      "to"         => Map.get(args, "to"),
      "subject"    => Map.get(args, "subject")
    }
  end

  defp sheets_append_row(args) do
    %{sheets_updated_range: range} = sentinels()

    %{
      "spreadsheet_id" => Map.get(args, "spreadsheet_id"),
      "updated_range"  => range,
      "values"         => Map.get(args, "values") || []
    }
  end

  defp sheets_update_range(args) do
    %{
      "spreadsheet_id" => Map.get(args, "spreadsheet_id"),
      "updated_range"  => Map.get(args, "range"),
      "values"         => Map.get(args, "values") || []
    }
  end

  defp drive_download(args) do
    %{drive_download_body: body} = sentinels()

    %{
      "file_id"      => Map.get(args, "file_id"),
      "content"      => body,
      "content_type" => "text/plain"
    }
  end

  defp drive_create_folder(args) do
    %{drive_folder_new_id: fid} = sentinels()

    %{
      "folder_id" => fid,
      "name"      => Map.get(args, "name"),
      "parent_id" => Map.get(args, "parent_id")
    }
  end

  defp gcal_delete_event(args) do
    %{
      "ok"       => true,
      "event_id" => Map.get(args, "event_id"),
      "calendar_id" => Map.get(args, "calendar_id", "primary")
    }
  end

  # Identity pivot — sentinel email maps to a stable Directory user
  # resource so chain tests can prove the lookup was wired without
  # touching real Google. Surfaced at the top level (no `"data"`
  # envelope — Directory's `users.get` returns the user resource
  # flat, the FunctionSpec response wraps it in `%{"user" => body}`).
  defp directory_users_find_by_email(args) do
    email = Map.get(args, "email", "")

    case email do
      "mock-user@example.com" ->
        %{
          "id"           => "MOCKGWUSER001",
          "primaryEmail" => "mock-user@example.com",
          "name"         => %{"fullName" => "Mock User"}
        }

      _ ->
        %{}
    end
  end
end
