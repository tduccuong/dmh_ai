# Session-walk regression: when the model emits a close-verb tool
# call with NO narration alongside (the bug you caught yesterday),
# the chain must still emit a chain-end signal the FE can poll on.
#
# Production failure mode: cancel_task fired with text_chars=0,
# narration empty → BE persisted no assistant message → FE polled
# forever waiting for `sawAssistantMessage`. The hang.
#
# This walk drives that exact shape: cancel_task with no
# accompanying text, asserts a `chain_end` SessionProgress row
# fires, asserts session.tool_history is clean (the cancelled task
# routed to archive, not the rolling window).

defmodule Itgr.SessionWalkCloseVerbTermination do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "swcvt_#{user_id}@itgr.local", "user", now])
  end

  defp insert_session(session_id, user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, "assistant", "[]", now, now])
  end

  test "cancel_task with empty narration → chain_end row fires; FE termination unblocked" do
    user_id    = uid()
    session_id = uid()
    seed_user(user_id)
    insert_session(session_id, user_id)

    [obs1, obs2] =
      T.session_walk(user_id, session_id, [
        # Chain 1: open a task, then immediately abandon it via
        # cancel_task with NO narration (the bug shape).
        {"start something", [
          fn _msgs, _tools ->
            {:tool_calls, [
              T.tool_call("create_task", %{
                "task_type"  => "one_off",
                "task_title" => "do thing",
                "task_spec"  => "do the thing",
                "language"   => "en"
              })
            ]}
          end,
          fn _msgs, _tools ->
            # Empty-narration cancel_task — exact shape that hung
            # the FE in the production trace from 2026-05-06.
            {:tool_calls, [
              T.tool_call("cancel_task", %{"task_num" => 1})
            ]}
          end
        ]},

        # Chain 2: a follow-up turn just to verify the runtime is
        # not wedged after the close-verb chain ended.
        {"hi again", [
          fn _msgs, _tools -> {:text, "Hi."} end
        ]}
      ])

    # Chain 1's chain_end row exists with cause "close_verb".
    chain_end_row =
      Enum.find(obs1.progress, fn r ->
        r.kind == "chain_end" and r.label == "close_verb"
      end)

    assert chain_end_row != nil,
           "expected chain_end row with cause=close_verb after cancel_task with empty narration. " <>
             "Without it the FE polls forever; got progress kinds: " <>
             inspect(obs1.progress |> Enum.map(&{&1.kind, &1.label}))

    # The cancelled task is gone from the rolling window AND from
    # the model's view going forward.
    assert Enum.all?(obs2.tool_history, fn entry ->
      Map.get(entry, "task_num") != 1
    end), "cancelled task 1 must not survive in tool_history into chain 2"

    # Runtime is responsive — chain 2 reached final_text without
    # hanging.
    assert Enum.any?(obs2.progress, fn r ->
      r.kind == "chain_end" and r.label == "final_text"
    end), "chain 2 should run to completion after the prior cancel"
  end
end
