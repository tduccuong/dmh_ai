# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03M365FunctionsTest do
  @moduledoc """
  Pins every Microsoft 365 function against the mock vendor MCP
  server — sibling to the Google Workspace `itgr_p03_gw_functions`
  suite. Same proof pattern: each assertion checks a fixture-only
  sentinel string in the response, so its presence in the result
  is mechanical proof that the dispatch path reached the mock
  rather than the model inventing similar-sounding output.

  Read functions (no task gate): mail.search · cal.find_free_slots ·
  files.list.
  Write functions (task required + idempotency_key): mail.send ·
  cal.create_event · files.upload.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.Mock.Fixtures.M365, as: M365Fixtures
  alias DmhAi.Connectors.M365
  alias DmhAi.Tools.Dispatcher

  @slug "m365"
  @canonical "mock-m365-resource"

  setup do
    Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
    Dispatcher.reset()
    :ok = Dispatcher.register(M365)

    %{url: mock_url} = T.start_mock_vendor("m365_functions_test", M365Fixtures.fixtures())
    user_id = T.transient_user()
    :ok = T.seed_mcp_authorization(user_id, @slug, @canonical, mock_url)

    {:ok, %{user_id: user_id, sentinels: M365Fixtures.sentinels()}}
  end

  describe "read functions (free chat, no task required)" do
    test "mail.search returns fixture messages cited by sentinel email",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"messages" => msgs}} =
               Dispatcher.call("m365.mail.search",
                               %{"query" => "from:beispiel"},
                               %{user_id: user_id})

      from_addresses = Enum.map(msgs, & &1["from"])
      assert s.anna_email   in from_addresses
      assert s.stefan_email in from_addresses
    end

    test "cal.find_free_slots returns at least one slot with the fixture's exact start time",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"slots" => [slot | _]}} =
               Dispatcher.call("m365.cal.find_free_slots",
                               %{
                                 "duration_min" => 45,
                                 "between_from" => "2026-05-22T09:00:00Z",
                                 "between_to"   => "2026-05-22T17:00:00Z"
                               },
                               %{user_id: user_id})

      assert slot["start"] == s.free_slot
      assert slot["duration_min"] == 45
    end

    test "files.list returns the fixture OneDrive file + folder",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"items" => items}} =
               Dispatcher.call("m365.files.list",
                               %{},
                               %{user_id: user_id})

      assert is_list(items)
      assert Enum.any?(items, fn item -> item["name"] == s.onedrive_file end)
      assert Enum.any?(items, fn item -> item["name"] == s.onedrive_folder end)
    end

    test "todo.list returns the fixture task by title",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"tasks" => tasks}} =
               Dispatcher.call("m365.todo.list", %{}, %{user_id: user_id})

      assert Enum.any?(tasks, fn t -> t["title"] == s.todo_title end)
    end

    test "contacts.search returns the fixture contact",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"contacts" => contacts}} =
               Dispatcher.call("m365.contacts.search",
                               %{"query" => "Maria"}, %{user_id: user_id})

      assert Enum.any?(contacts, fn c -> c["email"] == s.contact_email end)
    end

    test "excel.read_range returns the fixture cell value",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"values" => rows}} =
               Dispatcher.call("m365.excel.read_range",
                               %{
                                 "workbook_id" => "drv_m365_excel_mock_001",
                                 "worksheet"   => "Sheet1",
                                 "range"       => "A1:B2"
                               },
                               %{user_id: user_id})

      assert Enum.any?(rows, fn row -> s.excel_value in row end)
    end
  end

  describe "write functions (require active task + carry idempotency_key)" do
    test "mail.send inside a task returns accepted=true",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-m365-send", step_seq: 0}

      assert {:ok, %{"accepted" => true}} =
               Dispatcher.call("m365.mail.send",
                               %{"to" => s.anna_email, "subject" => "Hi", "body" => "Test"},
                               ctx)
    end

    test "cal.create_event inside a task returns the fixture event id + web_link",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-m365-cal", step_seq: 0}

      assert {:ok, %{"event_id" => id, "web_link" => link}} =
               Dispatcher.call("m365.cal.create_event",
                               %{
                                 "title" => "Q2 Reporting Sync",
                                 "start" => "2026-05-22T10:00:00Z",
                                 "end"   => "2026-05-22T10:45:00Z"
                               },
                               ctx)

      assert id == s.event_id
      assert is_binary(link) and String.contains?(link, id)
    end

    test "files.upload inside a task returns a generated file_id + web_url",
         %{user_id: user_id} do
      ctx = %{user_id: user_id, task_id: "t-m365-upload", step_seq: 0}

      assert {:ok, %{"file_id" => fid, "name" => name, "web_url" => url}} =
               Dispatcher.call("m365.files.upload",
                               %{
                                 "name"    => "Onboarding_M365_Pilot.docx",
                                 "content" => "fixture-content-placeholder"
                               },
                               ctx)

      assert is_binary(fid) and String.starts_with?(fid, "drv_m365_mock_uploaded_")
      assert name == "Onboarding_M365_Pilot.docx"
      assert is_binary(url) and String.contains?(url, name)
    end

    test "teams.create_meeting inside a task returns the fixture join URL",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-m365-teams", step_seq: 0}

      assert {:ok, %{"join_url" => url, "meeting_id" => id}} =
               Dispatcher.call("m365.teams.create_meeting",
                               %{"subject" => "Q2 sync"},
                               ctx)

      assert url == s.teams_join_url
      assert id  == s.teams_meeting_id
    end

    test "todo.create inside a task returns a generated task id",
         %{user_id: user_id} do
      ctx = %{user_id: user_id, task_id: "t-m365-todo-create", step_seq: 0}

      assert {:ok, %{"task_id" => tid, "title" => title}} =
               Dispatcher.call("m365.todo.create",
                               %{"title" => "Prepare slides"},
                               ctx)

      assert is_binary(tid) and String.starts_with?(tid, "task_m365_mock_created_")
      assert title == "Prepare slides"
    end
  end

  describe "manifest verifier" do
    test "manifest functions and fixture functions agree (no drift)" do
      functions_in_manifest =
        M365.manifest().functions |> Map.keys() |> Enum.sort()

      functions_in_fixtures =
        M365Fixtures.fixtures() |> Map.keys() |> Enum.sort()

      assert functions_in_manifest == functions_in_fixtures,
             """
             Manifest functions and fixture functions disagree.
             In manifest only: #{inspect(functions_in_manifest -- functions_in_fixtures)}
             In fixtures only: #{inspect(functions_in_fixtures -- functions_in_manifest)}
             """
    end
  end
end
