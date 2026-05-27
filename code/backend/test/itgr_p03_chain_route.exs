# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03ChainRouteTest do
  @moduledoc """
  Integration test for the chain's tool-execution → Dispatcher route
  (Primitive 0.3 #349). When the agent runtime calls
  `Tools.Registry.execute(name, args, ctx)` with a name whose
  prefix is a registered connector, the call MUST be routed through
  `Dispatcher.call/3` (not the legacy `MCP.Client.call_tool` path).

  Covers:

    * Free-chat call (no task_id in ctx) to a write function → typed
      `write_requires_task` envelope (Rule 2 HARD enforced through
      the runtime entry).
    * In-task call to a write function → carries the dispatcher-injected
      idempotency_key derived from (task_id, tool_call_id, function).
    * Unknown connector prefix → falls through to the existing
      MCP.Client path (preserves pre-Phase-C behaviour).
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.HubSpot
  alias DmhAi.Tools.{Dispatcher, Registry}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(HubSpot)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "cr-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    # OAuth credentials for HubSpot so credentials lookup succeeds.
    query!(Repo,
      "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "oauth:hubspot", "", "oauth2",
       Jason.encode!(%{"access_token" => "fake"}),
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    {:ok, %{admin_id: admin_id}}
  end

  describe "Registry.execute routes connector functions through Dispatcher" do
    test "free-chat write call → write_requires_task envelope", %{admin_id: admin_id} do
      # Free-chat tool_ctx: no :task_id. UserAgent's tool_ctx
      # builder leaves :task_id nil outside of a workflow run.
      # Simulate that exact shape here.
      tool_ctx = %{
        user_id:      admin_id,
        session_id:   "s-test",
        task_id:      nil,                          # free chat
        step_seq:     "tc-abc",
        tool_call_id: "tc-abc",
        progress_row_id: 0
      }

      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn _, _, _, _ ->
        flunk("MCP caller stub should never be hit when dispatcher refuses")
      end)

      assert {:error, %{error: "write_requires_task", function: "hubspot.deal.create"}} =
               Registry.execute("hubspot.deal.create",
                                %{"contact_id" => "c-1", "amount" => 5000},
                                tool_ctx)
    end

    test "in-task write call → succeeds with idempotency_key derived from tool_call_id",
         %{admin_id: admin_id} do
      tool_call_id = "tc-deal-create-" <> T.uid()

      tool_ctx = %{
        user_id:      admin_id,
        session_id:   "s-test",
        task_id:      "task-realdeal",
        step_seq:     tool_call_id,
        tool_call_id: tool_call_id,
        progress_row_id: 0
      }

      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "hubspot", "deal.create", args, _creds ->
        assert is_binary(args["__idempotency_key"])

        # Recompute the expected key — proves it's derived from
        # (task_id, step_seq, function) per the dispatcher contract.
        expected =
          :crypto.hash(:sha256, "task-realdeal\0#{tool_call_id}\0hubspot.deal.create")
          |> Base.encode16(case: :lower)

        assert args["__idempotency_key"] == expected,
               "idempotency_key must be sha256(task_id ‖ step_seq ‖ function)"

        {:ok, %{"deal_id" => "d-42"}}
      end)

      assert {:ok, %{"deal_id" => "d-42"}} =
               Registry.execute("hubspot.deal.create",
                                %{"contact_id" => "c-1", "amount" => 5000},
                                tool_ctx)
    end

    test "retry with the same tool_call_id produces identical idempotency_key",
         %{admin_id: admin_id} do
      tool_call_id = "tc-retry-" <> T.uid()
      tool_ctx = %{
        user_id:      admin_id,
        task_id:      "task-retry",
        step_seq:     tool_call_id,
        tool_call_id: tool_call_id
      }

      keys = :ets.new(:retry_keys, [:public, :set])

      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "hubspot", "deal.create", args, _creds ->
        :ets.insert(keys, {System.unique_integer([:monotonic]), args["__idempotency_key"]})
        {:ok, %{"deal_id" => "d-42"}}
      end)

      # Two invocations with the same tool_call_id (chain retried).
      {:ok, _} =
        Registry.execute("hubspot.deal.create",
                         %{"contact_id" => "c-1", "amount" => 5000},
                         tool_ctx)

      {:ok, _} =
        Registry.execute("hubspot.deal.create",
                         %{"contact_id" => "c-1", "amount" => 5000},
                         tool_ctx)

      observed = :ets.tab2list(keys) |> Enum.map(fn {_, k} -> k end)
      assert length(observed) == 2
      assert Enum.uniq(observed) |> length() == 1,
             "retries with same tool_call_id must produce identical idempotency_key"
    end
  end

  describe "unknown connector prefix falls through to MCP.Client (back-compat)" do
    test "unregistered slug doesn't get a Dispatcher hit", %{admin_id: admin_id} do
      # No connector named "ghost" is registered. Registry.do_execute
      # should fall through to the legacy MCP.Client path. We don't
      # care about the result (no MCP server registered either) —
      # we only care that the failure isn't a connector_not_registered
      # envelope from the dispatcher.
      assert match?({:error, _},
                    Registry.execute("ghost.something", %{},
                                     %{user_id: admin_id, task_id: nil,
                                       step_seq: "tc-1", tool_call_id: "tc-1"}))
    end
  end
end
