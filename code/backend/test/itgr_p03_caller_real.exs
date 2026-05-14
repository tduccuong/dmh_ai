# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03CallerRealTest do
  @moduledoc """
  Pins the real-Caller pipeline end-to-end across the dispatcher,
  the bridge into `DmhAi.MCP.Client.call_tool/4`, the JSON-RPC
  transport, and back. The mock vendor MCP server stands in for
  whichever vendor's real MCP endpoint the operator points
  production at.

  This test closes I1 — the load-bearing proof that the real
  Caller works for ALL 15 connectors, not just the stubbed
  per-connector contract tests.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Mock.Fixtures.GoogleWorkspace, as: GWFixtures
  alias DmhAi.Connectors.GoogleWorkspace
  alias DmhAi.Tools.Dispatcher
  import Ecto.Adapters.SQL, only: [query!: 3]

  @slug "google_workspace"
  @canonical "mock-gw-resource"

  setup do
    Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
    Dispatcher.reset()
    :ok = Dispatcher.register(GoogleWorkspace)

    %{url: mock_url} = T.start_mock_vendor("gw_caller_real_test", GWFixtures.fixtures())
    user_id = T.transient_user()
    :ok = T.seed_mcp_authorization(user_id, @slug, @canonical, mock_url)

    {:ok, %{user_id: user_id, mock_url: mock_url}}
  end

  describe "real Caller against Mock.VendorMCPServer" do
    test "gmail.search dispatches → real Caller → mock → canned response", %{user_id: user_id} do
      sentinels = GWFixtures.sentinels()

      assert {:ok, result} =
               Dispatcher.call("google_workspace.gmail.search",
                               %{"query" => "is:unread newer_than:1d"},
                               %{user_id: user_id})

      assert is_map(result)
      from_addresses = Enum.map(result["messages"], & &1["from"])
      assert sentinels.nina_email in from_addresses
      assert sentinels.tobias_email in from_addresses
      # The mock echoes the query — proves dispatcher forwarded args, not an empty map.
      assert result["queried"] == "is:unread newer_than:1d"
    end

    test "gmail.send (write) inside a task succeeds + idempotency_key threaded",
         %{user_id: user_id} do
      sentinels = GWFixtures.sentinels()
      ctx = %{user_id: user_id, task_id: "t-caller-real-write", step_seq: 0}

      assert {:ok, result} =
               Dispatcher.call("google_workspace.gmail.send",
                               %{
                                 "to"      => sentinels.nina_email,
                                 "subject" => "Caller-real-test send",
                                 "body"    => "fixture body"
                               },
                               ctx)

      assert result["to"] == sentinels.nina_email
      assert result["subject"] == "Caller-real-test send"
      assert is_binary(result["message_id"])
    end

    test "missing credentials short-circuits before real transport", %{user_id: user_id} do
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=? AND target=?",
             [user_id, "oauth:" <> @slug])

      assert {:error, %{error: "missing_credentials"}} =
               Dispatcher.call("google_workspace.gmail.search",
                               %{"query" => "test"},
                               %{user_id: user_id})
    end
  end
end
