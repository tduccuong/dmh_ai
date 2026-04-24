# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.UserAgentMessages do
  @moduledoc """
  Shared helper for appending an assistant/user message to a session's
  `messages` JSON column. Extracted so background processes (TaskRuntime,
  periodic completion flows) can write session messages without going
  through the per-user GenServer.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Append a message to the session's `messages` JSON column and stamp its
  `ts` from the BE clock (overwriting any incoming value) per CLAUDE.md
  rule #9. Returns `{:ok, ts_ms}` on success so callers can plumb the
  canonical timestamp back through their response (e.g. /agent/chat's
  final SSE `{done, user_ts, assistant_ts}` frame).

  Idempotency: if `message` carries a `:client_msg_id` / `"client_msg_id"`
  key and an entry with the same `client_msg_id` already exists in the
  session's messages, this call is a no-op and returns the **existing**
  `ts`. Lets FE retries after a lost POST response resolve to the same
  canonical row instead of creating a duplicate — see architecture.md
  §Mid-chain user message injection.
  """
  def append(session_id, user_id, message) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                      [session_id, user_id])

      case result.rows do
        [[msgs_json]] ->
          msgs = Jason.decode!(msgs_json || "[]")

          case idempotent_match(msgs, message) do
            {:match, existing_ts} ->
              Logger.info("[UserAgentMessages] idempotent match client_msg_id=#{inspect(message[:client_msg_id] || message["client_msg_id"])} returning existing ts=#{existing_ts}")
              {:ok, existing_ts}

            :no_match ->
              now  = System.os_time(:millisecond)
              stamped = Map.put(message, :ts, now)
              updated = Jason.encode!(msgs ++ [stamped])
              query!(Repo, "UPDATE sessions SET messages=?, updated_at=? WHERE id=?",
                     [updated, now, session_id])
              {:ok, now}
          end

        _ ->
          Logger.warning("[UserAgentMessages] session not found id=#{session_id}")
          {:error, :session_not_found}
      end
    rescue
      e ->
        Logger.error("[UserAgentMessages] append failed: #{Exception.message(e)}")
        {:error, :exception}
    end
  end

  # When `message` carries a `client_msg_id`, walk the existing messages
  # list looking for an entry with the same id. If found, surface the
  # persisted entry's `ts` so the caller reports the canonical BE
  # timestamp. Messages without a client_msg_id (e.g. assistant replies,
  # synthetic injections) always produce `:no_match` — idempotency only
  # applies to FE-originated user messages that supplied the key.
  defp idempotent_match(msgs, message) do
    incoming = message[:client_msg_id] || message["client_msg_id"]

    if is_binary(incoming) and incoming != "" do
      case Enum.find(msgs, fn m -> m["client_msg_id"] == incoming end) do
        %{"ts" => ts} when is_integer(ts) -> {:match, ts}
        _                                  -> :no_match
      end
    else
      :no_match
    end
  end

  @doc """
  Return user-role messages in `session.messages` whose `ts` is strictly
  greater than `after_ts`. Used by `session_turn_loop` to splice newly-
  arrived user messages into the live chain's LLM context on the next
  roundtrip (see architecture.md §Mid-chain user message injection).

  Returns a list of string-keyed maps as stored in the DB (same shape
  the context builder already handles).
  """
  @spec user_msgs_since(String.t(), integer()) :: [map()]
  def user_msgs_since(session_id, after_ts) when is_integer(after_ts) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

      case result.rows do
        [[msgs_json]] ->
          (msgs_json || "[]")
          |> Jason.decode!()
          |> Enum.filter(fn m ->
            (m["role"] || "") == "user" and is_integer(m["ts"]) and m["ts"] > after_ts
          end)

        _ ->
          []
      end
    rescue
      e ->
        Logger.error("[UserAgentMessages] user_msgs_since failed: #{Exception.message(e)}")
        []
    end
  end

  @doc """
  True when the session's last persisted message is role="user" — i.e.
  the user sent something and the assistant hasn't replied yet. Used
  by the chain-complete hook and the boot-time orphan scan to decide
  whether to auto-dispatch a fresh Assistant turn.
  """
  @spec has_unanswered_user_msg?(String.t()) :: boolean()
  def has_unanswered_user_msg?(session_id) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

      case result.rows do
        [[msgs_json]] ->
          case Jason.decode!(msgs_json || "[]") |> List.last() do
            %{"role" => "user"} -> true
            _                    -> false
          end

        _ ->
          false
      end
    rescue
      e ->
        Logger.error("[UserAgentMessages] has_unanswered_user_msg? failed: #{Exception.message(e)}")
        false
    end
  end

  @doc """
  Return messages in `session.messages` tagged with `task_num` whose
  `ts` is strictly greater than `floor_ts`. Used by `fetch_task` to
  stitch archive (everything up to `floor_ts`) with live (everything
  after). Preserves every field on the message so the caller can pass
  them to the model unchanged.
  """
  @spec messages_for_task_num(String.t(), integer(), integer()) :: [map()]
  def messages_for_task_num(session_id, task_num, floor_ts)
      when is_binary(session_id) and is_integer(task_num) and is_integer(floor_ts) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

      case result.rows do
        [[msgs_json]] ->
          (msgs_json || "[]")
          |> Jason.decode!()
          |> Enum.filter(fn m ->
            is_map(m) and m["task_num"] == task_num and
              is_integer(m["ts"]) and m["ts"] > floor_ts
          end)

        _ ->
          []
      end
    rescue
      e ->
        Logger.error("[UserAgentMessages] messages_for_task_num failed: #{Exception.message(e)}")
        []
    end
  end

  @doc """
  Across all of `user_id`'s Assistant-mode sessions, return the session
  ids whose last persisted message is role="user" — the orphan set the
  UserAgent boot scan dispatches fresh turns for. See architecture.md
  §Boot scan for orphan recovery.
  """
  @spec sessions_with_unanswered_user_msg(String.t()) :: [String.t()]
  def sessions_with_unanswered_user_msg(user_id) do
    try do
      result = query!(Repo,
        "SELECT id, messages FROM sessions WHERE user_id=? AND mode='assistant'",
        [user_id])

      Enum.flat_map(result.rows, fn [session_id, msgs_json] ->
        case Jason.decode!(msgs_json || "[]") |> List.last() do
          %{"role" => "user"} -> [session_id]
          _                    -> []
        end
      end)
    rescue
      e ->
        Logger.error("[UserAgentMessages] sessions_with_unanswered_user_msg failed: #{Exception.message(e)}")
        []
    end
  end
end
