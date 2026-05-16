# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03GoogleWorkspaceFunctionsTest do
  @moduledoc """
  Pins every Google Workspace function against the mock vendor MCP
  server. Closes I3 for GW: every function is grounded in a real
  Google API endpoint AND the shim-layer translation contract is
  exercised through the dispatcher.

  Read functions (no task gate): gmail.search · gcal.find_free_slots ·
  drive.list.
  Write functions (task required + idempotency_key): gmail.send ·
  gcal.create_event · drive.upload.

  Each assertion checks a fixture-only sentinel string in the
  response — the same proof pattern the 0.2 demos used
  ("28 Tage" / "dmh-prod-sev1" / "urn:dmh-sme-demo:saml"): the
  string is unique to this fixture, so its presence in the result
  is mechanical proof that the dispatch path reached the mock
  rather than an unrelated source.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.Mock.Fixtures.GoogleWorkspace, as: GWFixtures
  alias DmhAi.Connectors.GoogleWorkspace
  alias DmhAi.Tools.Dispatcher

  @slug "google_workspace"
  @canonical "mock-gw-resource"

  setup do
    Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
    Dispatcher.reset()
    :ok = Dispatcher.register(GoogleWorkspace)

    %{url: mock_url} = T.start_mock_vendor("gw_functions_test", GWFixtures.fixtures())
    user_id = T.transient_user()
    :ok = T.seed_mcp_authorization(user_id, @slug, @canonical, mock_url)

    {:ok, %{user_id: user_id, sentinels: GWFixtures.sentinels()}}
  end

  describe "read functions (free chat, no task required)" do
    test "gmail.search returns fixture messages cited by sentinel email",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"messages" => msgs}} =
               Dispatcher.call("google_workspace.gmail.search",
                               %{"query" => "label:inbox"},
                               %{user_id: user_id})

      assert s.nina_email   in Enum.map(msgs, & &1["from"])
      assert s.tobias_email in Enum.map(msgs, & &1["from"])
    end

    test "gcal.find_free_slots returns at least one slot with the fixture's exact start time",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"slots" => [slot | _]}} =
               Dispatcher.call("google_workspace.gcal.find_free_slots",
                               %{
                                 "duration_min" => 45,
                                 "between_from" => "2026-05-21T09:00:00+02:00",
                                 "between_to"   => "2026-05-21T17:00:00+02:00"
                               },
                               %{user_id: user_id})

      assert slot["start"] == s.free_slot
      assert slot["duration_min"] == 45
    end

    test "drive.list returns the fixture file in the fixture folder",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"items" => items}} =
               Dispatcher.call("google_workspace.drive.list",
                               %{"folder_id" => s.drive_folder_id},
                               %{user_id: user_id})

      assert is_list(items)
      assert Enum.any?(items, fn item -> item["name"] == s.drive_file end)
    end

    test "tasks.list returns the fixture task by title",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"tasks" => tasks}} =
               Dispatcher.call("google_workspace.tasks.list", %{}, %{user_id: user_id})

      assert Enum.any?(tasks, fn t -> t["title"] == s.task_title end)
    end

    test "contacts.search returns the fixture contact",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"contacts" => contacts}} =
               Dispatcher.call("google_workspace.contacts.search",
                               %{"query" => "Petra"}, %{user_id: user_id})

      assert Enum.any?(contacts, fn c -> c["email"] == s.contact_email end)
    end

    test "sheets.read_range returns the fixture cell value",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"values" => rows}} =
               Dispatcher.call("google_workspace.sheets.read_range",
                               %{"spreadsheet_id" => "sheet-mock-001", "range" => "Sheet1!A1:B2"},
                               %{user_id: user_id})

      assert Enum.any?(rows, fn row -> s.sheet_value in row end)
    end
  end

  describe "write functions (require active task + carry idempotency_key)" do
    test "gmail.send outside an active task is refused (dispatcher gate)",
         %{user_id: user_id, sentinels: s} do
      assert {:error, %{error: "write_requires_task"}} =
               Dispatcher.call("google_workspace.gmail.send",
                               %{"to" => s.nina_email, "subject" => "x", "body" => "y"},
                               %{user_id: user_id})
    end

    test "gmail.send inside a task succeeds; mock echoes addressee",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-gw-send", step_seq: 0}

      assert {:ok, %{"to" => to, "message_id" => mid}} =
               Dispatcher.call("google_workspace.gmail.send",
                               %{"to" => s.nina_email, "subject" => "Hi", "body" => "Test"},
                               ctx)

      assert to == s.nina_email
      assert is_binary(mid) and String.starts_with?(mid, "msg_mock_sent_")
    end

    test "gcal.create_event inside a task returns the fixture event id",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-gw-cal", step_seq: 0}

      assert {:ok, %{"event_id" => id}} =
               Dispatcher.call("google_workspace.gcal.create_event",
                               %{
                                 "title" => "Meeting mit Externer GmbH",
                                 "start" => "2026-05-21T14:30:00+02:00",
                                 "end"   => "2026-05-21T15:15:00+02:00"
                               },
                               ctx)

      assert id == s.event_id
    end

    test "drive.upload inside a task returns a generated file_id",
         %{user_id: user_id} do
      ctx = %{user_id: user_id, task_id: "t-gw-upload", step_seq: 0}

      assert {:ok, %{"file_id" => fid, "name" => name}} =
               Dispatcher.call("google_workspace.drive.upload",
                               %{
                                 "name"    => "Vertrag_Mustermann_2026-05.txt",
                                 "content" => "MIME-content-base64-encoded-placeholder"
                               },
                               ctx)

      assert is_binary(fid) and String.starts_with?(fid, "drv_mock_uploaded_")
      assert name == "Vertrag_Mustermann_2026-05.txt"
    end

    test "meet.create_meeting inside a task returns the fixture join URL",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-gw-meet", step_seq: 0}

      assert {:ok, %{"join_url" => url, "meeting_code" => code}} =
               Dispatcher.call("google_workspace.meet.create_meeting", %{}, ctx)

      assert url == s.meet_join_url
      assert code == s.meet_code
    end

    test "tasks.create inside a task returns a generated task id",
         %{user_id: user_id} do
      ctx = %{user_id: user_id, task_id: "t-gw-tasks", step_seq: 0}

      assert {:ok, %{"task_id" => tid, "title" => title}} =
               Dispatcher.call("google_workspace.tasks.create",
                               %{"title" => "Beleg fotografieren"},
                               ctx)

      assert is_binary(tid) and String.starts_with?(tid, "task_gw_mock_created_")
      assert title == "Beleg fotografieren"
    end
  end

  describe "manifest verifier" do
    test "diff against the mock's tools/list reports zero divergence" do
      # The mock derives its tools/list from the fixtures map, which
      # uses the same function names the manifest declares. This is a
      # sanity gate: if anyone ADDS a function to the manifest without
      # also adding a fixture, this fails — surfaces an unfinished
      # I3 audit before the per-function test below catches it as a
      # missing-fixture error.
      functions_in_manifest =
        GoogleWorkspace.manifest().functions |> Map.keys() |> Enum.sort()

      functions_in_fixtures =
        GWFixtures.fixtures() |> Map.keys() |> Enum.sort()

      assert functions_in_manifest == functions_in_fixtures,
             """
             Manifest functions and fixture functions disagree.
             In manifest only: #{inspect(functions_in_manifest -- functions_in_fixtures)}
             In fixtures only: #{inspect(functions_in_fixtures -- functions_in_manifest)}
             """
    end
  end
end
