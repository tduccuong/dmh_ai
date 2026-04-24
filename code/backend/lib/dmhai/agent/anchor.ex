# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Anchor do
  @moduledoc """
  The "active task anchor" — the single source of truth for which task
  a given chain is for. See architecture.md §Active-task anchor.

  `resolve/2` derives the current anchor (a map with `:task_num` and
  `:task_id`, or `nil`) from the session's current state plus optional
  caller hints. Called by:

    * `ContextEngine.build_assistant_messages/2` — to inject the
      anchor block at the tail of the LLM context AND to tag assistant
      messages / user messages with `task_num` at persist time.
    * `Dmhai.Handlers.AgentChat.handle_assistant_chat/4` — to tag
      incoming user messages with the task_num they implicitly refine
      (via `session.messages` persistence).
    * `Dmhai.Agent.UserAgent` silent-turn entry — passes
      `silent_turn_task_id` as a hint.

  Priority order (highest → lowest):

    1. **`silent_turn_task_id` in opts** — scheduler-triggered silent
       pickup names the task explicitly. Always wins.
    2. **Exactly one `ongoing` task in the session** — the session has
       a single active task in flight; that's the anchor.
    3. **Exactly one `ongoing` + `pending` non-periodic task** — if
       no ongoing, fall back to a single pending one_off task. This
       handles the post-rehydrate / post-crash case where ongoing
       state was briefly lost, and sessions with one queued task.
    4. **Nothing matches** — returns `nil`. Free mode: the model's
       next meaningful action is usually `create_task`.

  Periodic tasks are NEVER picked as the anchor by the priority rules
  above (except via rule 1 when the scheduler explicitly names them).
  A periodic task sitting pending in the list is waiting for the
  scheduler to trigger it; it shouldn't hijack a user-initiated
  chain's focus.
  """

  alias Dmhai.Agent.Tasks

  @type anchor :: %{task_num: integer(), task_id: String.t()} | nil
  @type opts :: Keyword.t() | map()

  @doc """
  Resolve the anchor for a session. Returns a map with `:task_num` and
  `:task_id` keys, or `nil` when no anchor can be determined (free
  mode). See module doc for priority rules.

  Options:
    * `:silent_turn_task_id` — when set, forces the anchor to this
      task id (used by silent periodic pickups). The function still
      looks up `task_num` and returns the map shape.
  """
  @spec resolve(String.t(), opts) :: anchor
  def resolve(session_id, opts \\ []) do
    silent_tid = get_opt(opts, :silent_turn_task_id)

    cond do
      is_binary(silent_tid) and silent_tid != "" ->
        case Tasks.get(silent_tid) do
          %{task_id: tid, task_num: tn} when is_integer(tn) ->
            %{task_num: tn, task_id: tid}
          _ ->
            nil
        end

      true ->
        resolve_from_session_state(session_id)
    end
  end

  @doc """
  Convenience: return just the `task_num` integer (or nil). Handy for
  tagging persisted messages where the id is not needed.
  """
  @spec task_num_for(String.t(), opts) :: integer() | nil
  def task_num_for(session_id, opts \\ []) do
    case resolve(session_id, opts) do
      %{task_num: n} -> n
      _              -> nil
    end
  end

  # ── private ────────────────────────────────────────────────────────

  defp get_opt(opts, key) when is_list(opts),  do: Keyword.get(opts, key)
  defp get_opt(opts, key) when is_map(opts),   do: Map.get(opts, key)
  defp get_opt(_, _),                          do: nil

  defp resolve_from_session_state(session_id) do
    active = Tasks.active_for_session(session_id)

    case pick_anchor(active) do
      nil  -> nil
      task -> %{task_num: task.task_num, task_id: task.task_id}
    end
  end

  # Apply the priority rules to an `active_for_session` list.
  # active_for_session returns tasks in: pending, ongoing, paused.
  defp pick_anchor(active) do
    ongoing = Enum.filter(active, &(&1.task_status == "ongoing"))

    cond do
      # Rule 2: exactly one ongoing → that's the anchor.
      length(ongoing) == 1 ->
        List.first(ongoing)

      # Rule 2': multiple ongoing → pick the most-recently-updated one.
      # Shouldn't happen in normal operation (chain at a time), but
      # gracefully handles race conditions.
      length(ongoing) > 1 ->
        Enum.max_by(ongoing, fn t -> Map.get(t, :updated_at) || 0 end)

      # Rule 3: no ongoing → fall back to a single pending one_off
      # task. Skip periodic (those wait for scheduler) and tasks with
      # non-integer task_num (legacy rows pre-task_num column).
      true ->
        pending_oneoff =
          active
          |> Enum.filter(fn t ->
            t.task_status == "pending" and t.task_type == "one_off" and
              is_integer(Map.get(t, :task_num))
          end)

        case pending_oneoff do
          [single] -> single
          _        -> nil
        end
    end
  end
end
