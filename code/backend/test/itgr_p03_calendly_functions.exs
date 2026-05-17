# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03CalendlyFunctionsTest do
  @moduledoc """
  Pins every Calendly function against the mock vendor MCP server.
  Sibling to the GW + M365 + HubSpot function suites — same proof
  pattern: each assertion checks a fixture-only sentinel string in
  the response so its presence proves the dispatch path reached
  the mock rather than the model inventing similar-sounding output.

  Read functions (no task gate): user.me · event_type.list ·
  event_type.available_slots · event.list · event.invitees.
  Write functions (task required + idempotency_key):
  single_use_link.create · event.cancel · event.mark_no_show.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.Mock.Fixtures.Calendly, as: CalendlyFixtures
  alias DmhAi.Connectors.Calendly
  alias DmhAi.Tools.Dispatcher

  @slug "calendly"
  @canonical "mock-calendly-resource"

  setup do
    Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
    Dispatcher.reset()
    :ok = Dispatcher.register(Calendly)

    %{url: mock_url} = T.start_mock_vendor("calendly_functions_test", CalendlyFixtures.fixtures())
    user_id = T.transient_user()
    :ok = T.seed_mcp_authorization(user_id, @slug, @canonical, mock_url)

    {:ok, %{user_id: user_id, sentinels: CalendlyFixtures.sentinels()}}
  end

  describe "read functions (free chat, no task required)" do
    test "user.me returns the fixture identity", %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"user" => user}} =
               Dispatcher.call("calendly.user.me", %{}, %{user_id: user_id})

      assert user["email"] == s.user_email
      assert user["name"]  == s.user_name
      assert user["uri"]   == s.user_uri
    end

    test "event_type.list returns the fixture event type", %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"event_types" => types}} =
               Dispatcher.call("calendly.event_type.list", %{}, %{user_id: user_id})

      assert Enum.any?(types, fn t -> t["uri"]  == s.event_type_uri  end)
      assert Enum.any?(types, fn t -> t["name"] == s.event_type_name end)
    end

    test "event_type.available_slots returns ≥1 slot", %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"slots" => slots}} =
               Dispatcher.call("calendly.event_type.available_slots",
                               %{
                                 "event_type_uri" => s.event_type_uri,
                                 "start_time"     => "2026-05-20T00:00:00Z",
                                 "end_time"       => "2026-05-21T00:00:00Z"
                               },
                               %{user_id: user_id})

      assert is_list(slots) and slots != []
    end

    test "event.list returns the fixture event", %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"events" => events}} =
               Dispatcher.call("calendly.event.list", %{}, %{user_id: user_id})

      assert Enum.any?(events, fn e -> e["uri"]  == s.event_uri  end)
      assert Enum.any?(events, fn e -> e["name"] == s.event_name end)
    end

    test "event.invitees returns the fixture invitee", %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"invitees" => invitees}} =
               Dispatcher.call("calendly.event.invitees",
                               %{"event_uri" => s.event_uri},
                               %{user_id: user_id})

      assert Enum.any?(invitees, fn i -> i["email"] == s.invitee_email end)
      assert Enum.any?(invitees, fn i -> i["name"]  == s.invitee_name  end)
    end
  end

  describe "write functions (require active task + carry idempotency_key)" do
    test "single_use_link.create outside an active task is refused (dispatcher gate)",
         %{user_id: user_id, sentinels: s} do
      assert {:error, %{error: "write_requires_task"}} =
               Dispatcher.call("calendly.single_use_link.create",
                               %{"event_type_uri" => s.event_type_uri},
                               %{user_id: user_id})
    end

    test "single_use_link.create inside a task returns a booking URL",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-cal-link", step_seq: 0}

      assert {:ok, %{"booking_url" => url}} =
               Dispatcher.call("calendly.single_use_link.create",
                               %{"event_type_uri" => s.event_type_uri},
                               ctx)

      assert is_binary(url) and String.starts_with?(url, s.booking_url)
    end

    test "event.cancel inside a task confirms the cancellation",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-cal-cancel", step_seq: 0}

      assert {:ok, %{"cancelled" => true, "event_uri" => uri}} =
               Dispatcher.call("calendly.event.cancel",
                               %{"event_uri" => s.event_uri, "reason" => "Customer rescheduled"},
                               ctx)

      assert uri == s.event_uri
    end

    test "event.mark_no_show inside a task records the no-show",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-cal-no-show", step_seq: 0}

      assert {:ok, %{"marked" => true, "no_show_uri" => uri}} =
               Dispatcher.call("calendly.event.mark_no_show",
                               %{"invitee_uri" => s.invitee_uri},
                               ctx)

      assert is_binary(uri) and String.starts_with?(uri, s.no_show_uri)
    end
  end

  describe "manifest verifier" do
    test "manifest functions and fixture functions agree (no drift)" do
      functions_in_manifest =
        Calendly.manifest().functions |> Map.keys() |> Enum.sort()

      functions_in_fixtures =
        CalendlyFixtures.fixtures() |> Map.keys() |> Enum.sort()

      assert functions_in_manifest == functions_in_fixtures,
             """
             Manifest functions and fixture functions disagree.
             In manifest only: #{inspect(functions_in_manifest -- functions_in_fixtures)}
             In fixtures only: #{inspect(functions_in_fixtures -- functions_in_manifest)}
             """
    end
  end

  describe "MCP tools/list rendering" do
    test "inputSchema carries real argument names + required flags from the manifest" do
      handler = DmhAi.Connectors.Calendly.MCPHandler.handler()
      tools   = DmhAi.Connectors.MCPServer.tools_list_for(handler)

      slc =
        Enum.find(tools, fn t -> t["name"] == "single_use_link.create" end)

      assert slc, "single_use_link.create missing from rendered tools/list"

      schema = slc["inputSchema"]
      assert schema["type"] == "object"

      props = schema["properties"]
      assert Map.has_key?(props, "event_type_uri"),
             "tools/list must expose the real arg name `event_type_uri` so the model doesn't guess (regression test for the empty-properties bug)"
      assert props["event_type_uri"]["type"] == "string"

      assert "event_type_uri" in (schema["required"] || []),
             "event_type_uri is required and must appear in the schema's `required` array"

      # Optional argument is in properties but NOT in required.
      assert Map.has_key?(props, "max_event_count")
      assert props["max_event_count"]["type"] == "integer"
      refute "max_event_count" in (schema["required"] || [])
    end
  end
end
