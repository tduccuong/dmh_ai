# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F18 — Police's SOFT post-execution advisory for two consecutive
# `run_script`s.
#
# When the assistant emits `run_script` and the immediately preceding
# tool call was also `run_script`, `Police.consecutive_run_script_advisory/2`
# returns an educational note that the runtime PREPENDS to the tool
# result content. The script still runs (no rejection, no
# `[[ISSUE:...]]` marker, no nudge counter, no telemetry row) — the
# note teaches the model what a proper `run_script` looks like and
# names two anti-patterns to watch for.
#
# This is the only "soft" Police path — distinct from the hard gates
# tested in F17 (`check_run_script_probe_budget`, etc).
#
# What this flow validates:
#   * Turn 0: model emits `run_script`. No advisory (no prior
#     run_script) — tool_result is the raw stubbed output.
#   * Turn 1: model emits a SECOND `run_script` back-to-back. The
#     advisory is prepended to that turn's tool_result.
#   * Turn 2: model returns plain text → chain ends cleanly.
#   * The advisory does NOT fire `bump_nudge_counters` — the
#     `[[ISSUE:...]]` marker is absent and `model_behavior_stats`
#     stays empty for this issue.
#
# `run_script` itself is faked via the `__tool_execute_stub__` hook
# (see `T.stub_tool/1`) so the test doesn't depend on Docker / the
# Python sandbox image.

defmodule DmhAi.Flows.F18SoftNudgeTeaches do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.Tasks
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F18"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F18")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, org_id, org_role, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
       DmhAi.Constants.default_org_id(), "admin",
       System.os_time(:millisecond)])

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [session_id, user_id, "assistant", "[]", "[]",
       System.os_time(:millisecond), System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM session_progress WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "two consecutive run_scripts → advisory prefixed on the 2nd tool_result, not the 1st",
       %{user_id: user_id, session_id: session_id} do
    # Seed an ongoing task so the chain has an anchor.
    Tasks.insert(%{
      user_id:     user_id,
      session_id:  session_id,
      task_type:   "one_off",
      task_title:  "investigate disk usage",
      task_spec:   "investigate why /var is filling up",
      task_status: "ongoing",
      language:    "en"
    })

    # Stub Swift classifier — chain-start side-channel call.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

    # Stub run_script: return a canned "exit 0 / stdout=…" string.
    # All other tools fall through to the real Registry.
    T.stub_tool(fn name, args, _ctx ->
      case name do
        "run_script" ->
          script = args["script"] || args[:script] || ""
          {:ok, "[stubbed run_script]\nscript=#{script}\nstdout=ok\nexit=0\n"}

        _other ->
          :passthrough
      end
    end)

    rs1_id = "rs-1"
    rs2_id = "rs-2"

    [obs] =
      T.session_walk(user_id, session_id, [
        {"why is /var filling up?",
         [
           # Turn 0 — first run_script. No advisory (no prior run_script).
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => rs1_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "run_script",
                   "arguments" => %{"script" => "ls /var | head"}
                 }}]}
           end,

           # Turn 1 — second run_script back-to-back. Advisory PREPENDED.
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => rs2_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "run_script",
                   "arguments" => %{"script" => "du -sh /var/* | sort -h"}
                 }}]}
           end,

           # Turn 2 — final text. Chain ends.
           fn _msgs, _tools ->
             {:text, "Looked at /var; biggest consumers are logs and cache."}
           end
         ]}
      ])

    # ── Assertions ──────────────────────────────────────────────────
    #
    # Tool calls + results live in `sessions.tool_history` (JSON array
    # of `{assistant_ts, ts, task_num, messages: […]}` entries —
    # `messages` carries the role=assistant + role=tool pairs). They
    # are NOT persisted into `sessions.messages` (which is user-facing
    # turns only). See `lib/dmh_ai/agent/tool_history.ex` moduledoc.
    tool_msgs =
      obs.tool_history
      |> Enum.flat_map(fn entry -> entry["messages"] || [] end)
      |> Enum.filter(fn m -> (m["role"] || m[:role]) == "tool" end)

    assert length(tool_msgs) == 2,
           "expected exactly 2 tool_result messages in tool_history (one per run_script); got: #{length(tool_msgs)}; full tool_history: #{inspect(obs.tool_history)}"

    rs1_result = Enum.find(tool_msgs, fn m -> (m["tool_call_id"] || m[:tool_call_id]) == rs1_id end)
    rs2_result = Enum.find(tool_msgs, fn m -> (m["tool_call_id"] || m[:tool_call_id]) == rs2_id end)

    assert rs1_result, "missing tool_result for first run_script (#{rs1_id})"
    assert rs2_result, "missing tool_result for second run_script (#{rs2_id})"

    rs1_content = (rs1_result["content"] || rs1_result[:content]) |> to_string()
    rs2_content = (rs2_result["content"] || rs2_result[:content]) |> to_string()

    # Turn 0 — NO advisory.
    refute rs1_content =~ "⚠ RUNTIME WARNING",
           "first run_script should NOT carry the consecutive-advisory; got: #{inspect(rs1_content)}"

    # The stubbed body landed.
    assert rs1_content =~ "[stubbed run_script]",
           "first run_script result should contain the stubbed body; got: #{inspect(rs1_content)}"

    # Turn 1 — advisory present AND prepended (it leads the body).
    assert String.starts_with?(rs2_content, "[⚠ RUNTIME WARNING"),
           "second run_script result should START with the alarming WARNING advisory; got: #{inspect(rs2_content)}"

    assert rs2_content =~ "Consecutive `run_script`s used",
           "advisory header should call out the consecutive-run_scripts pattern; got: #{inspect(rs2_content)}"

    assert rs2_content =~ "SCAN your context FIRST",
           "advisory should lead with the context-scan directive; got: #{inspect(rs2_content)}"

    assert rs2_content =~ "You MUST COMPOSE",
           "advisory should command compose-not-probe; got: #{inspect(rs2_content)}"

    assert rs2_content =~ "Re-PLAN, don't re-PROBE",
           "advisory should cover the failure-replan rule; got: #{inspect(rs2_content)}"

    # Stubbed body is still present after the advisory prefix.
    assert rs2_content =~ "[stubbed run_script]",
           "second run_script result should still contain the stubbed body after the advisory; got: #{inspect(rs2_content)}"

    # Soft nudge MUST NOT carry an [[ISSUE:...]] marker — that's the
    # contract that distinguishes it from hard rejections in F17.
    refute rs2_content =~ "[[ISSUE:",
           "soft advisory must NOT carry an [[ISSUE:...]] marker " <>
             "(would falsely bump nudge counters); got: #{inspect(rs2_content)}"

    # Soft nudge MUST NOT record telemetry under the consecutive-
    # run_script issue type. Double-check via the stats table.
    %{rows: stat_rows} = query!(Repo,
      "SELECT issue_type FROM model_behavior_stats WHERE issue_type LIKE ?",
      ["%consecutive_run_script%"])

    assert stat_rows == [],
           "soft advisory must not write any model_behavior_stats row; got: #{inspect(stat_rows)}"

    # Chain ended cleanly with the model's plain-text turn.
    final_msg =
      obs.messages
      |> Enum.filter(fn m ->
           role = m["role"] || m[:role]
           role == "assistant" and is_binary(m["content"] || m[:content])
         end)
      |> List.last()

    assert final_msg, "expected a final assistant text message"
    final_content = (final_msg["content"] || final_msg[:content]) |> to_string()
    assert final_content =~ "/var",
           "final text should reference the topic; got: #{inspect(final_content)}"

    chain_ended? =
      obs.progress
      |> Enum.any?(fn r -> Map.get(r, :kind) == "chain_end" end)

    assert chain_ended?, "expected a chain_end progress row at the end of the chain"
  end

  test "advisory alternates: fires on the 2nd and 4th run_script, NOT on the 3rd",
       %{user_id: user_id, session_id: session_id} do
    # If the model treats the 2nd-call advisory seriously and emits a
    # properly-composed multi-step script as the 3rd call, scolding it
    # AGAIN with the same advisory reads as a contradictory scolding.
    # Police's `consecutive_run_script_advisory/2` therefore alternates:
    # advisory on the 2nd, quiet on the 3rd, advisory again on the 4th
    # (last-warning), quiet on the 5th, hard reject at the 6th from the
    # `check_run_script_probe_budget` gate.

    Tasks.insert(%{
      user_id:     user_id,
      session_id:  session_id,
      task_type:   "one_off",
      task_title:  "stress alternation",
      task_spec:   "fire 4 run_scripts and observe the advisory rhythm",
      task_status: "ongoing",
      language:    "en"
    })

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

    T.stub_tool(fn name, args, _ctx ->
      case name do
        "run_script" ->
          script = args["script"] || args[:script] || ""
          {:ok, "[stubbed]\nscript=#{script}\nstdout=ok\nexit=0\n"}

        _ ->
          :passthrough
      end
    end)

    [obs] =
      T.session_walk(user_id, session_id, [
        {"do four probes",
         [
           fn _msgs, _tools ->
             {:tool_calls, [%{"id" => "rs-a-1", "type" => "function",
               "function" => %{"name" => "run_script",
                                "arguments" => %{"script" => "echo 1"}}}]}
           end,
           fn _msgs, _tools ->
             {:tool_calls, [%{"id" => "rs-a-2", "type" => "function",
               "function" => %{"name" => "run_script",
                                "arguments" => %{"script" => "echo 2"}}}]}
           end,
           fn _msgs, _tools ->
             {:tool_calls, [%{"id" => "rs-a-3", "type" => "function",
               "function" => %{"name" => "run_script",
                                "arguments" => %{"script" => "echo 3"}}}]}
           end,
           fn _msgs, _tools ->
             {:tool_calls, [%{"id" => "rs-a-4", "type" => "function",
               "function" => %{"name" => "run_script",
                                "arguments" => %{"script" => "echo 4"}}}]}
           end,
           fn _msgs, _tools ->
             {:text, "Done with the four probes."}
           end
         ]}
      ])

    tool_msgs =
      obs.tool_history
      |> Enum.flat_map(fn entry -> entry["messages"] || [] end)
      |> Enum.filter(fn m -> (m["role"] || m[:role]) == "tool" end)
      |> Enum.sort_by(fn m -> m["tool_call_id"] || m[:tool_call_id] end)

    assert length(tool_msgs) == 4,
           "expected 4 tool_result messages (one per run_script); got: #{length(tool_msgs)}"

    [r1, r2, r3, r4] = tool_msgs
    [c1, c2, c3, c4] = Enum.map([r1, r2, r3, r4], fn m ->
      to_string(m["content"] || m[:content] || "")
    end)

    refute c1 =~ "⚠ RUNTIME WARNING",
           "1st run_script must NOT carry the advisory; got: #{inspect(c1)}"

    assert c2 =~ "⚠ RUNTIME WARNING",
           "2nd run_script SHOULD carry the advisory; got: #{inspect(c2)}"

    refute c3 =~ "⚠ RUNTIME WARNING",
           "3rd run_script must NOT carry the advisory — alternation rule " <>
             "(re-warning a properly-composed compose-turn would confuse the " <>
             "model); got: #{inspect(c3)}"

    assert c4 =~ "⚠ RUNTIME WARNING",
           "4th run_script SHOULD carry the advisory (last warning before " <>
             "the hard 6th-call cap); got: #{inspect(c4)}"
  end
end
