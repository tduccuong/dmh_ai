# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03GoogleWorkspaceVerbsTest do
  @moduledoc """
  Pins every Google Workspace verb against the mock vendor MCP
  server. Closes I3 for GW: every verb is grounded in a real
  Google API endpoint AND the shim-layer translation contract is
  exercised through the dispatcher.

  Read verbs (no task gate): gmail.search · gcal.find_free_slots ·
  drive.list.
  Write verbs (task required + idempotency_key): gmail.send ·
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

    %{url: mock_url} = T.start_mock_vendor("gw_verbs_test", GWFixtures.fixtures())
    user_id = T.transient_user()
    :ok = T.seed_mcp_authorization(user_id, @slug, @canonical, mock_url)

    {:ok, %{user_id: user_id, sentinels: GWFixtures.sentinels()}}
  end

  describe "read verbs (free chat, no task required)" do
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
  end

  describe "write verbs (require active task + carry idempotency_key)" do
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
  end

  describe "manifest verifier" do
    test "diff against the mock's tools/list reports zero divergence" do
      # The mock derives its tools/list from the fixtures map, which
      # uses the same verb names the manifest declares. This is a
      # sanity gate: if anyone ADDS a verb to the manifest without
      # also adding a fixture, this fails — surfaces an unfinished
      # I3 audit before the per-verb test below catches it as a
      # missing-fixture error.
      verbs_in_manifest =
        GoogleWorkspace.manifest().verbs |> Map.keys() |> Enum.sort()

      verbs_in_fixtures =
        GWFixtures.fixtures() |> Map.keys() |> Enum.sort()

      assert verbs_in_manifest == verbs_in_fixtures,
             """
             Manifest verbs and fixture verbs disagree.
             In manifest only: #{inspect(verbs_in_manifest -- verbs_in_fixtures)}
             In fixtures only: #{inspect(verbs_in_fixtures -- verbs_in_manifest)}
             """
    end
  end
end
