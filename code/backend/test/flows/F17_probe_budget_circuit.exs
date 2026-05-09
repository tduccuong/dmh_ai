# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F17 — `run_script` probe budget hard cap.
#
# `Police.check_run_script_probe_budget/3` REJECTS the (N+1)th
# `run_script` tool_call when the chain-scoped accumulator already
# contains `AgentSettings.run_script_probe_budget()` (default 5)
# of them. The rejection shape is
# `{:rejected, {:run_script_probe_budget, reason}}` — the runtime
# wraps that into a tool_result tagged `[[ISSUE:run_script_probe_budget:run_script]]`,
# `bump_nudge_counters/2` strips the marker and increments
# `ctx.nudges[:run_script_probe_budget]`, and on the 3rd hit
# `maybe_abort_on_model_behavior_issue/2` fires the friendly
# `circuit_breaker_message(:run_script_probe_budget)` copy.
#
# This flow validates the GATE — the load-bearing piece. The gate's
# accumulator is chain-scoped (`Enum.drop(messages, chain_start_idx)`
# inside `execute_tools/3`); pre-seeded prior session messages do
# NOT count, so we test the gate at value level with a
# `prior_messages` argument that mirrors the chain accumulator's
# shape.
#
# The 3-strike circuit-breaker is generic infrastructure shared with
# every other gate's nudge atom (search budget, task discipline, …)
# and is exercised end-to-end whenever a chain accumulates nudges.
# Its copy lookup `circuit_breaker_message/1` is private to
# `UserAgent`; making it public would let a flow assert each branch
# directly. Out of scope for F17.

defmodule DmhAi.Flows.F17ProbeBudgetCircuit do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{AgentSettings, Police}

  @moduletag flow_id: "F17"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F17")
    on_exit(teardown)
    :ok
  end

  describe "Police.check_run_script_probe_budget/3" do
    test "passes under the budget" do
      budget = AgentSettings.run_script_probe_budget()
      under  = build_run_script_history(budget - 1)

      assert Police.check_run_script_probe_budget("run_script", %{}, under) == :ok,
             "gate must pass with #{budget - 1} prior run_scripts (under budget #{budget})"
    end

    test "rejects at the budget — issue atom + nudge prose" do
      budget = AgentSettings.run_script_probe_budget()
      prior  = build_run_script_history(budget)

      assert {:rejected, {:run_script_probe_budget, reason}} =
               Police.check_run_script_probe_budget("run_script", %{}, prior),
             "gate must reject the #{budget + 1}th run_script after #{budget} prior calls"

      # Issue atom is the load-bearing handle: the runtime tags the
      # tool_result `[[ISSUE:run_script_probe_budget:run_script]]`,
      # `bump_nudge_counters/2` keys `ctx.nudges` on this atom, and
      # `circuit_breaker_message/1` switches on it for the friendly
      # copy. Renaming the atom in either place silently breaks the
      # whole pipeline — assert it explicitly.
      assert is_binary(reason)
      assert reason =~ "probed enough",
             "rejection reason should explain the cap; got: #{inspect(reason)}"
      assert reason =~ "ONE",
             "rejection reason should suggest combining into ONE script; got: #{inspect(reason)}"
      assert reason =~ "ask the user",
             "rejection reason should suggest asking the user as the alternative; got: #{inspect(reason)}"
    end

    test "rejects above the budget too" do
      budget = AgentSettings.run_script_probe_budget()
      well_over = build_run_script_history(budget * 2)

      assert {:rejected, {:run_script_probe_budget, _}} =
               Police.check_run_script_probe_budget("run_script", %{}, well_over),
             "gate must keep rejecting once over budget — not just at the boundary"
    end

    test "no-ops for tools other than run_script" do
      assert Police.check_run_script_probe_budget("web_search", %{"q" => "x"}, []) == :ok
      assert Police.check_run_script_probe_budget("create_task", %{}, []) == :ok
      assert Police.check_run_script_probe_budget("complete_task", %{}, []) == :ok
    end

    test "ignores non-run_script entries when counting prior history" do
      budget = AgentSettings.run_script_probe_budget()

      mixed =
        build_run_script_history(budget - 1) ++
          [
            %{role: "assistant",
              tool_calls: [%{
                "id" => "ws-1",
                "type" => "function",
                "function" => %{"name" => "web_search", "arguments" => %{"q" => "x"}}
              }]},
            %{role: "user", content: "hi"},
            %{role: "tool", content: "stuff", tool_call_id: "ws-1"}
          ]

      # `count_run_script_calls/1` only counts assistant tool_calls
      # named "run_script"; mixed entries (web_search, user, tool)
      # must be skipped — count stays under budget → gate passes.
      assert Police.check_run_script_probe_budget("run_script", %{}, mixed) == :ok,
             "gate should ignore non-run_script entries — only count run_script tool_calls"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # Build a `prior_messages` shape that
  # `Police.count_run_script_calls/1` will count `n` run_scripts in.
  # Mirrors the chain-loop accumulator's atom-key + tool_calls shape.
  defp build_run_script_history(n) do
    for i <- 1..n//1 do
      %{
        role: "assistant",
        tool_calls: [%{
          "id"       => "tc-#{i}",
          "type"     => "function",
          "function" => %{"name" => "run_script", "arguments" => %{"script" => "echo #{i}"}}
        }]
      }
    end
  end
end
