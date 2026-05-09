# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F11 — cross-task pickup with envelope rendering.
#
# Scenario: a session has a closed (`done`) task with prior chain
# archived. User sends a follow-up message related to that task. The
# chain-prep Swift classifier matches the message against the closed
# task's spec/title; runtime injects a guidance hint into the LLM-call
# user message; the assistant fires `pickup_task(N)`; the tool result
# is the `<requested_task_content number="N">` envelope, with the
# archive's tool_call shells visible but no tool_result bodies.
#
# Drives the assistant via the live `UserAgent.dispatch_assistant/2`
# path (through `T.session_walk/3`) with stubbed LLMs (no real LLM
# calls). Pre-seeds the closed task + archive directly via SQL —
# focus stays on the resume flow, not on the prior task's full
# creation/run lifecycle.

defmodule DmhAi.Flows.F11CrossTaskResume do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.Tasks
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F11"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F11")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
       System.os_time(:millisecond)])

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [session_id, user_id, "assistant", "[]", "[]",
       System.os_time(:millisecond), System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM task_chain_archive WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "follow-up → Swift match → runtime hint → pickup_task → envelope",
       %{user_id: user_id, session_id: session_id} do
    # 1. Seed a closed task with archive content.
    task_id =
      Tasks.insert(%{
        user_id:    user_id,
        session_id: session_id,
        task_type:  "one_off",
        task_title: "install daemon on server X",
        task_spec:  "install daemon on server X via apt; verify port 8080",
        task_status: "done",
        language:   "en"
      })

    %{task_num: task_num} = Tasks.get(task_id)
    Tasks.mark_done(task_id, "Installed; running on :8080.")

    # Pre-fill archive with prior-chain content (assistant + tool_call
    # shell, no tool_results — matches the eviction rule applied at
    # task-close time).
    DmhAi.Agent.TaskChainArchive.append_raw(task_id, session_id, [
      %{role: "user",
        content: "install daemon on server X via apt; verify port 8080",
        ts: 1},
      %{role: "assistant",
        content: "Provisioning SSH and running the install.",
        ts: 2},
      %{role: "assistant",
        content: nil,
        tool_calls: [
          %{"id" => "tc-1",
            "type" => "function",
            "function" => %{
              "name" => "run_script",
              "arguments" => %{"script" => "ssh user@host 'apt install -y daemon'"}
            }}
        ],
        ts: 3},
      %{role: "assistant",
        content: "Daemon installed; service running on :8080.",
        ts: 4}
    ])

    # 2. Stub Swift's classify_against_inactive — returns a single
    # token "task_num". The classifier hits LLM.call (not .stream).
    swift_calls = :counters.new(1, [:atomics])

    T.stub_llm_call(fn _model, msgs, _opts ->
      :counters.add(swift_calls, 1, 1)

      user_content =
        Enum.find_value(msgs, "", fn
          %{role: "user", content: c}            -> c
          %{"role" => "user", "content" => c}    -> c
          _                                       -> nil
        end)

      assert user_content =~ "install daemon on server X",
             "Swift's prompt should list the inactive task; got: #{inspect(user_content)}"

      {:ok, Integer.to_string(task_num)}
    end)

    # 3. Drive the chain via session_walk. Two assistant turns:
    #    turn 0: emit pickup_task(N) after seeing the runtime hint.
    #    turn 1: emit final text after seeing the envelope.
    pickup_call_id = "pt-1"

    [obs] =
      T.session_walk(user_id, session_id, [
        {"X is broken, the daemon won't respond — check and fix",
         [
           fn msgs, _tools ->
             last_user =
               msgs
               |> Enum.reverse()
               |> Enum.find(fn m -> (m[:role] || m["role"]) == "user" end)

             content =
               (last_user || %{})[:content] ||
                 (last_user || %{})["content"] || ""

             assert content =~ "<runtime_hint>",
                    "expected <runtime_hint> in the latest user message after Swift match; got: #{inspect(content)}"

             assert content =~ "pickup_task(#{task_num})",
                    "hint should name pickup_task(#{task_num}); got: #{inspect(content)}"

             {:tool_calls,
              [%{"id" => pickup_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "pickup_task",
                   "arguments" => %{"task_num" => task_num}
                 }}]}
           end,
           fn msgs, _tools ->
             pickup_result =
               Enum.find(msgs, fn m ->
                 (m[:role] || m["role"]) == "tool" and
                   ((m[:tool_call_id] || m["tool_call_id"]) == pickup_call_id)
               end)

             assert pickup_result, "expected pickup_task tool result in turn-1 messages"

             body = (pickup_result[:content] || pickup_result["content"]) |> to_string()

             assert body =~ "<requested_task_content number=\"#{task_num}\">",
                    "envelope opener not found in tool result; got:\n#{body}"

             assert body =~ "[assistant→run_script]",
                    "archive transcript should include the run_script call shell; got:\n#{body}"

             refute body =~ "[tool] ",
                    "envelope must NOT contain any [tool] role lines"

             {:text, "Re-running the install script — task is back to ongoing."}
           end
         ]}
      ])

    # 4. Cross-cutting assertions on the observation snapshot.
    assert :counters.get(swift_calls, 1) >= 1,
           "Swift classifier should have fired at least once on this chain"

    final_msg = obs.messages |> List.last() || %{}
    final_content = (final_msg["content"] || final_msg[:content]) |> to_string()
    assert final_content =~ "Re-running the install script",
           "final assistant text should be persisted; got: #{inspect(final_content)}"

    %{task_status: status} = Tasks.get(task_id)
    assert status == "ongoing",
           "pickup_task should have flipped task #{task_num} to ongoing; got: #{status}"
  end
end
