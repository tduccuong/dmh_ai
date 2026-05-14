# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F23 — closed-task tool-result eviction visible end-to-end.
#
# Scenario: a task runs with `run_script`, generates tool_call +
# tool_result entries in tool_history, then closes via complete_task.
# After close, every visible surface (tool_history, task_chain_archive,
# fetch_task return shape, pickup_task envelope) must show no
# tool-result content for that task — only the call shells survive.
#
# This flow exercises: Tasks.create/complete_task, ToolHistory write +
# flush, TaskChainArchive write filter, fetch_task closed-task branch,
# pickup_task envelope rendering. No LLM call — pure backend
# integration.

defmodule DmhAi.Flows.F23ClosedTaskEviction do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{Tasks, ToolHistory, TaskChainArchive}
  alias DmhAi.Tools.{FetchTask, PickupTask}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F23"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F23")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
       DmhAi.Constants.default_org_id(), "admin",
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

  test "closed-task tool_results are evicted across every visible surface",
       %{user_id: user_id, session_id: session_id} do
    # Step 1: create a task in the session.
    task_id =
      Tasks.insert(%{
        user_id:    user_id,
        session_id: session_id,
        task_type:  "one_off",
        task_title: "install daemon on server X",
        task_spec:  "install daemon on server X",
        task_status: "ongoing",
        language:   "en"
      })

    %{task_num: task_num} = Tasks.get(task_id)

    # Step 2: simulate a chain that produced a run_script tool_call +
    # tool_result. Persist as a tool_history group on the session row,
    # tagged with task_num — the same shape `save_tools_result_of_chain`
    # writes during a real chain.
    chain_msgs = [
      %{
        "role" => "assistant",
        "content" => "Running the install script on the host.",
        "tool_calls" => [
          %{
            "id" => "tc-1",
            "type" => "function",
            "function" => %{
              "name" => "run_script",
              "arguments" => %{"script" => "ssh user@host apt install daemon"}
            }
          }
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "tc-1",
        "content" => "Installed: daemon 1.2.3-1; service running on :8080. " <>
                       String.duplicate("verbose-output ", 50)
      },
      %{
        "role" => "assistant",
        "content" => "Daemon installed successfully; service running on port 8080."
      }
    ]

    seed_tool_history(session_id,
      [%{"assistant_ts" => System.os_time(:millisecond),
         "task_num" => task_num,
         "messages" => chain_msgs}])

    # Sanity: tool_history holds the entry, including the tool_result
    # content, BEFORE close.
    pre_th = ToolHistory.load(session_id)
    assert length(pre_th) == 1
    assert pre_th |> List.first() |> Map.get("task_num") == task_num
    assert pre_th |> List.first() |> Map.get("messages")
                  |> Enum.any?(&(&1["role"] == "tool" && String.contains?(&1["content"], "verbose-output")))

    # Step 3: close the task (this is the action under test).
    Tasks.mark_done(task_id, "Installed; running on :8080.")

    # Step 4 — assertion 1: tool_history entries for this task are
    # gone after flush.
    post_th = ToolHistory.load(session_id)
    refute Enum.any?(post_th, &(Map.get(&1, "task_num") == task_num)),
           "expected closed task's tool_history entries to be flushed; got: #{inspect(post_th)}"

    # Step 5 — assertion 2: task_chain_archive for this task has NO
    # tool-result rows — only user/assistant.
    archive_roles =
      task_id
      |> TaskChainArchive.fetch_for_task()
      |> Enum.map(&Map.get(&1, :role))
      |> Enum.uniq()

    refute Enum.member?(archive_roles, "tool"),
           "archive must not contain role='tool' rows for closed task; got roles=#{inspect(archive_roles)}"

    # Step 6 — assertion 3: fetch_task returns tool_bodies = [] and
    # archive shape with no tool entries.
    {:ok, fetched} = FetchTask.execute(%{"task_num" => task_num},
                                       %{session_id: session_id})

    assert fetched.tool_bodies == [],
           "fetch_task on closed task must return empty tool_bodies; got: #{inspect(fetched.tool_bodies)}"

    refute Enum.any?(fetched.archive, &(Map.get(&1, :role) == "tool")),
           "fetch_task closed-task archive must have no role='tool' entries"

    # Step 7 — assertion 4: pickup_task envelope contains the
    # tool_call signature line but NO `[tool]` content line and none
    # of the tool_result body text.
    {:ok, envelope} = PickupTask.execute(%{"task_num" => task_num},
                                         %{session_id: session_id})

    assert String.contains?(envelope, "<requested_task_content number=\"#{task_num}\">"),
           "envelope must include opening tag for task_num=#{task_num}"

    # Tool_call shell visible:
    assert String.contains?(envelope, "[assistant→run_script]"),
           "envelope must show the run_script call shell; got:\n#{envelope}"

    # Tool_result body text NOT visible:
    refute String.contains?(envelope, "verbose-output"),
           "envelope must NOT contain the closed-task tool_result body content"

    # No `[tool]` role line should appear in the natural-text format:
    refute String.contains?(envelope, "[tool] "),
           "envelope must not render any `[tool]` role lines"
  end

  # Seed the session row's `tool_history` JSON column directly with the
  # given entries. Mirrors what `ToolHistory.save_tools_result_of_chain`
  # writes during a live chain — bypassing the chain plumbing keeps the
  # flow test focused on the close-time eviction behaviour.
  defp seed_tool_history(session_id, entries) do
    query!(Repo,
      "UPDATE sessions SET tool_history=? WHERE id=?",
      [Jason.encode!(entries), session_id])
  end
end
