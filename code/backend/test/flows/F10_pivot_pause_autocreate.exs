# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F10 — off-topic pivot, user pauses, runtime auto-creates a new
# task from the stashed pivot message.
#
# Chain 0 (off-topic message arrives while task A is the anchor):
#   * Swift classifies the user msg → `:unrelated`.
#   * Police rejects the assistant's non-exempt tool_call.
#   * Assistant retries with plain push-back text.
#   * `PendingPivots` is stashed (load-bearing side effect of
#     `maybe_start_swift` on `:unrelated`).
#
# Chain 1 (user replies "pause it"):
#   * Swift → `:related`.
#   * Assistant emits `pause_task(A)`.
#   * `auto_create_task` reads `PendingPivots`, synthesises a
#     `create_task` from the stashed off-topic message, anchor flips.
#
# Asserts: task A paused; new task exists with pivot msg as spec;
# PendingPivots cleared; anchor = new task_num.

defmodule DmhAi.Flows.F10PivotPauseAutocreate do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{Anchor, PendingPivots, Tasks}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F10"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F10")
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
      PendingPivots.clear(session_id)
      query!(Repo, "DELETE FROM task_chain_archive WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "off-topic → push-back → user pause → auto-create new task",
       %{user_id: user_id, session_id: session_id} do
    # 1. Seed an ongoing task A.
    task_a_id =
      Tasks.insert(%{
        user_id:    user_id,
        session_id: session_id,
        task_type:  "one_off",
        task_title: "configure backup",
        task_spec:  "configure nightly DB backup on the host",
        task_status: "ongoing",
        language:   "en"
      })

    %{task_num: task_a_num} = Tasks.get(task_a_id)

    # 2. Stub Swift's classify/3. Sequential verdicts:
    # `:unrelated` for chain 0, `:related` for chain 1.
    swift_calls = :counters.new(1, [:atomics])

    T.stub_llm_call(fn _model, _msgs, _opts ->
      idx = :counters.get(swift_calls, 1)
      :counters.add(swift_calls, 1, 1)

      verdict =
        case idx do
          0 -> "UNRELATED"
          _ -> "RELATED"
        end

      {:ok, verdict}
    end)

    # 3. Drive both chains via session_walk.
    pivot_msg     = "now install nginx as reverse proxy on this server"
    web_call_id   = "ws-1"
    pause_call_id = "pt-1"

    [_obs0, obs1] =
      T.session_walk(user_id, session_id, [
        # Chain 0: off-topic, Police rejects, push-back.
        {pivot_msg,
         [
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => web_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "web_search",
                   "arguments" => %{"q" => "how to install nginx"}
                 }}]}
           end,
           fn _msgs, _tools ->
             {:text, "I'm currently on task (#{task_a_num}). Pause / cancel that first?"}
           end
         ]},

        # Chain 1: pause task A → auto-create-task fires.
        {"pause it",
         [
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => pause_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "pause_task",
                   "arguments" => %{"task_num" => task_a_num}
                 }}]}
           end,
           fn _msgs, _tools ->
             {:text, "Paused (#{task_a_num}). Starting on the nginx install."}
           end
         ]}
      ])

    # 4. Cross-chain assertions.

    # Task A is paused.
    %{task_status: status_a} = Tasks.get(task_a_id)
    assert status_a == "paused",
           "expected task #{task_a_num} paused; got: #{status_a}"

    # A NEW task exists with the off-topic message as its spec.
    new_tasks =
      Tasks.list_for_session(session_id)
      |> Enum.reject(&(&1.task_id == task_a_id))

    assert length(new_tasks) == 1,
           "expected exactly 1 auto-created task; got: #{inspect(Enum.map(new_tasks, & &1.task_num))}"

    [new_task] = new_tasks

    assert new_task.task_spec =~ "install nginx",
           "auto-created task spec should include the pivot message; got: #{inspect(new_task.task_spec)}"

    # PendingPivots was consumed.
    assert PendingPivots.get(session_id) == nil,
           "PendingPivots should be cleared after auto-create-task fires"

    # Anchor flipped to the new task.
    assert Anchor.task_num_for(session_id) == new_task.task_num,
           "anchor should be the new task_num=#{new_task.task_num}; got: #{inspect(Anchor.task_num_for(session_id))}"

    # Sanity: chain-1 final assistant text persisted.
    final_msg = obs1.messages |> List.last() || %{}
    final_content = (final_msg["content"] || final_msg[:content]) |> to_string()
    assert final_content =~ "Paused" or final_content =~ "nginx",
           "final assistant text should reference paused task or nginx; got: #{inspect(final_content)}"

    assert :counters.get(swift_calls, 1) >= 2,
           "Swift should have classified at least 2 chain-start messages"
  end
end
