# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F12 — explicit cancel, no auto-create.
#
# Scenario: an active task is `ongoing`. User says "cancel". Model
# emits `cancel_task(N)`. The task flips to `cancelled` AND no new
# task is auto-synthesised (PendingPivots remains empty — explicit
# cancel is NOT a pivot). Anchor is cleared.
#
# The closely-related "off-topic pivot → user pause" flow that DOES
# auto-create is F10 (separate test).

defmodule DmhAi.Flows.F12ExplicitCancel do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{PendingPivots, Tasks}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F12"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F12")
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
      PendingPivots.clear(session_id)
      query!(Repo, "DELETE FROM task_chain_archive WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "user says 'cancel' → cancel_task fires → no auto-create-task",
       %{user_id: user_id, session_id: session_id} do
    # 1. Seed an ongoing task.
    task_id =
      Tasks.insert(%{
        user_id:    user_id,
        session_id: session_id,
        task_type:  "one_off",
        task_title: "configure backup",
        task_spec:  "configure nightly DB backup on the host",
        task_status: "ongoing",
        language:   "en"
      })

    %{task_num: task_num} = Tasks.get(task_id)

    # No PendingPivots stash before — clean slate.
    assert PendingPivots.get(session_id) == nil

    # 2. Stub Swift's anchored classifier — when an anchor exists, the
    # chain-start path runs `Swift.classify/3`; for an unambiguous
    # "cancel" message the verdict is `:related` (the user is acting
    # on the active task with an exempt verb). Stub via LLM.call.
    T.stub_llm_call(fn _model, _msgs, _opts ->
      # Single-token verdict; Swift parses to `:related`.
      {:ok, "RELATED"}
    end)

    # 3. Drive the chain via session_walk: one user msg "cancel",
    # one assistant turn that emits `cancel_task(N)`, then a closing
    # text turn.
    cancel_call_id = "ct-1"

    # Close-verb chains terminate immediately after `cancel_task`
    # succeeds (#228 — explicit chain_end on close verb). The runtime
    # synthesises the user-facing acknowledgment; no extra LLM turn
    # is invoked. Hence the walk has just ONE turn fn.
    [obs] =
      T.session_walk(user_id, session_id, [
        {"cancel",
         [
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => cancel_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "cancel_task",
                   "arguments" => %{"task_num" => task_num}
                 }}]}
           end
         ]}
      ])

    # 4. Task flipped to cancelled.
    %{task_status: status} = Tasks.get(task_id)
    assert status == "cancelled",
           "expected task #{task_num} to be cancelled; got: #{status}"

    # 5. PendingPivots was NOT stashed — explicit cancel is not a
    # pivot. Stash is what `do_auto_create_task` consumes to
    # synthesise a new task; staying empty proves no auto-create
    # fired.
    assert PendingPivots.get(session_id) == nil,
           "explicit cancel should not stash a pending pivot"

    # 6. Sanity: only the original task exists in the session — no
    # auto-created sibling.
    %{rows: rows} = query!(Repo,
      "SELECT COUNT(*) FROM tasks WHERE session_id = ?", [session_id])
    assert match?([[1]], rows),
           "exactly one task should remain in the session; got: #{inspect(rows)}"

    # 7. Chain ended cleanly — there's a `chain_end` progress row
    # after the cancel_task tool row. (Close-verb termination per
    # #228 — explicit chain_end progress row as FE termination
    # signal.)
    chain_ended? =
      obs.progress
      |> Enum.any?(fn r -> Map.get(r, :kind) == "chain_end" end)

    assert chain_ended?, "expected a chain_end progress row after cancel_task"
  end
end
