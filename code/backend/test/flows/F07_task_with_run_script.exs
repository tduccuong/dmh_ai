# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F07 — One-off task with `run_script`. The happy-path chain
# every other flow file is a variation of:
#
#   user "check disk usage"
#     ↓
#   chain: create_task → run_script (faked) → complete_task("usage:…")
#
# Validates the load-bearing pieces:
#
#   * `create_task` lands a row with `task_status="ongoing"` and the
#     anchor flips to it.
#   * `run_script`'s stub output flows back to the chain as a tool
#     result — proving the `T.stub_tool/1` hook short-circuits the
#     real dispatcher cleanly without breaking the rest of
#     `execute_tools/3`.
#   * `complete_task` closes the task. The session_walk stub can't
#     combine `tool_calls` and `content` in one LLM response, so the
#     close-verb fires with empty narration — the runtime then takes
#     the documented fall-through path (one extra LLM turn carries
#     the user-facing answer; chain ends on `final_text`).
#   * On task close, the chain's run_script + tool_result pair is
#     flushed out of `sessions.tool_history` and into
#     `task_chain_archive` (#229 — closed-task data lives in the
#     archive, never in the rolling window).
#   * `complete_task` progress row is hidden (the narration IS the
#     completion event from the user's POV; the row would just be
#     noise before the final answer renders).

defmodule DmhAi.Flows.F07TaskWithRunScript do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{Tasks, TaskChainArchive}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F07"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F07")
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
      query!(Repo, "DELETE FROM task_chain_archive WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "create_task → run_script (stubbed) → complete_task → archive populated, rolling cleared",
       %{user_id: user_id, session_id: session_id} do
    # Swift classifier — no anchor at start, so it returns :none
    # (free mode). Kept simple via stub_llm_call.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

    # Stub run_script. All other tools (create_task, complete_task)
    # fall through to the real Registry path.
    T.stub_tool(fn name, args, _ctx ->
      case name do
        "run_script" ->
          script = args["script"] || args[:script] || ""
          {:ok, "[stubbed run_script]\nscript=#{script}\n" <>
                "stdout=Filesystem  Size  Used Avail Use%\n/dev/sda1  100G   42G   58G  42%\nstdout_end\nexit=0\n"}

        _other ->
          :passthrough
      end
    end)

    create_call_id   = "ct-1"
    run_call_id      = "rs-1"
    complete_call_id = "cp-1"

    [obs] =
      T.session_walk(user_id, session_id, [
        {"check disk usage on the host",
         [
           # Turn 0 — create_task. Anchor flips to the new task.
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => create_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "create_task",
                   "arguments" => %{
                     "task_type"  => "one_off",
                     "task_title" => "check disk usage",
                     "task_spec"  => "report disk usage on the host",
                     "language"   => "en"
                   }
                 }}]}
           end,

           # Turn 1 — run_script. Stub returns canned df output.
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => run_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "run_script",
                   "arguments" => %{"script" => "df -h /"}
                 }}]}
           end,

           # Turn 2 — complete_task. The session_walk stub can't
           # combine tool_calls + content, so narration is empty
           # here; the runtime then runs one more LLM turn for the
           # user-facing answer (documented fall-through).
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => complete_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "complete_task",
                   "arguments" => %{
                     "task_num"    => 1,
                     "task_result" => "/dev/sda1 at 42% (42G/100G); fine."
                   }
                 }}]}
           end,

           # Turn 3 — delivery turn. The model writes the user-
           # facing answer based on the run_script output. Chain
           # ends on `final_text`.
           fn _msgs, _tools ->
             {:text,
              "Disk usage on the host: /dev/sda1 is at 42% " <>
                "(42G used of 100G). Plenty of headroom."}
           end
         ]}
      ])

    # Assertion 1 — exactly one task in the session, status=done.
    tasks = Tasks.list_for_session(session_id)
    assert length(tasks) == 1,
           "expected exactly one task created; got: #{inspect(Enum.map(tasks, & &1.task_num))}"

    [task] = tasks
    assert task.task_status == "done",
           "expected task closed (done); got: #{task.task_status}"

    assert is_binary(task.task_result) and task.task_result != "",
           "complete_task must persist a non-empty task_result; got: #{inspect(task.task_result)}"

    # Assertion 2 — closed-task data lives in the archive, not in
    # the rolling tool_history. (#229 invariant.)
    archive = TaskChainArchive.fetch_for_task(task.task_id)
    refute archive == [],
           "expected run_script + tool_result pair in task_chain_archive after complete_task; got empty"

    archive_role_seq = Enum.map(archive, fn r -> Map.get(r, :role) end)
    assert "tool" in archive_role_seq or "assistant" in archive_role_seq,
           "archive should contain the chain's role=assistant + role=tool messages; got roles: #{inspect(archive_role_seq)}"

    # The run_script script string survived into the archive (proves
    # the stub's output AND the assistant tool_call shell both got
    # archived together).
    archive_dump = Enum.map_join(archive, "\n", fn r -> to_string(Map.get(r, :content) || "") end)
    assert archive_dump =~ "df -h" or archive_dump =~ "stubbed run_script",
           "archive should contain the run_script call/result; got: #{inspect(archive_dump)}"

    # Rolling tool_history is empty (or has no entry for this task)
    # — closed-task pairs were flushed AND not re-saved at chain end.
    rolling =
      obs.tool_history
      |> Enum.filter(fn entry ->
           Map.get(entry, "task_num") == task.task_num or
             Map.get(entry, :task_num) == task.task_num
         end)

    assert rolling == [],
           "rolling tool_history must NOT carry pairs for the closed task (#229); got: #{inspect(rolling)}"

    # Assertion 3 — final assistant text is the delivery turn's
    # answer text (fn[3]). The complete_task turn carried empty
    # narration, so the runtime ran one more LLM turn whose plain
    # text is the user-facing answer.
    final_assistant =
      obs.messages
      |> Enum.filter(fn m ->
           role = m["role"] || m[:role]
           role == "assistant" and is_binary(m["content"] || m[:content])
         end)
      |> List.last()

    assert final_assistant, "expected a final assistant message"
    final_content = (final_assistant["content"] || final_assistant[:content]) |> to_string()

    assert final_content =~ "Disk usage" or final_content =~ "42%",
           "delivery turn text should contain the run_script-derived answer; " <>
             "got: #{inspect(final_content)}"

    # Assertion 4 — chain_end progress row, cause=final_text. The
    # session_walk stub can't combine tool_calls + content in one
    # response, so complete_task fires with empty narration; the
    # runtime takes the documented fall-through (one extra LLM
    # turn for delivery) and chain ends on the delivery turn's
    # plain text.
    chain_end_row =
      obs.progress
      |> Enum.find(fn r -> Map.get(r, :kind) == "chain_end" end)

    assert chain_end_row, "expected a chain_end progress row at chain termination"
    cause = Map.get(chain_end_row, :label) || Map.get(chain_end_row, "label")
    assert cause == "final_text",
           "complete_task with empty narration should end the chain on the " <>
             "delivery turn (final_text); got cause=#{inspect(cause)}"

    # Assertion 5 — complete_task's tool progress row is hidden
    # (the narration IS the user-facing answer; the row would be
    # noise before the final text renders).
    complete_row =
      obs.progress
      |> Enum.find(fn r ->
           kind = Map.get(r, :kind)
           label = Map.get(r, :label) || ""
           kind == "tool" and String.contains?(label, "complete_task")
         end)

    if complete_row do
      assert Map.get(complete_row, :hidden) == true,
             "complete_task's tool progress row should be hidden " <>
               "(noise before final answer); got: #{inspect(complete_row)}"
    end

    # Assertion 6 — create_task and run_script progress rows are
    # visible (state transitions / probe results the user wants to
    # see).
    visible_kinds =
      obs.progress
      |> Enum.filter(fn r ->
           kind = Map.get(r, :kind)
           hidden = Map.get(r, :hidden, false)
           kind == "tool" and not hidden
         end)
      |> Enum.map(fn r -> Map.get(r, :label) || "" end)

    # `ProgressLabel.format/2` renders verbs in CamelCase
    # ("CreateTask → …", "RunScript → …") for FE display; assert
    # case-insensitively against the verb stem.
    label_dump = Enum.map_join(visible_kinds, " | ", &String.downcase/1)

    assert label_dump =~ "createtask",
           "create_task progress row should be visible; got labels: #{inspect(visible_kinds)}"

    assert label_dump =~ "runscript",
           "run_script progress row should be visible; got labels: #{inspect(visible_kinds)}"
  end
end
