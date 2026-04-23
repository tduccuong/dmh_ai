# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.ToolHistory do
  @moduledoc """
  Per-session rolling window of the last N turns' tool_call / tool_result
  message pairs. Lets the Assistant answer immediate follow-up questions
  ("what does section 3 of that PDF say?") without re-running the tool,
  while ageing out naturally so context can't grow unbounded.

  Storage: `sessions.tool_history` TEXT column holding a JSON array:

      [
        {
          "assistant_ts": 1776940253417,  // ts of the final assistant text that closed this turn
          "ts":           1776940253417,  // when the entry was written (== assistant_ts)
          "messages": [
            %{"role" => "assistant", "content" => "", "tool_calls" => [...]},
            %{"role" => "tool",      "content" => "...", "tool_call_id" => "..."},
            ...
          ]
        },
        ...
      ]

  Two caps (applied on every save):
    * **Turn cap** — keep at most `AgentSettings.tool_result_retention_turns/0`
      most-recent entries (default 5).
    * **Byte cap** — if the combined JSON size of retained entries exceeds
      `AgentSettings.tool_result_retention_bytes/0` (default 120_000 chars),
      drop oldest-first until it fits.

  Typical sessions generate ~0-20 KB of tool output per turn; the byte
  cap only kicks in for extraction marathons.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Record a turn's tool messages against its final-assistant ts, then
  trim to the configured turn + byte caps.

  `tool_messages` is the subset of the turn's in-memory message list
  that has role="assistant" with tool_calls, or role="tool" with a
  tool_call_id. User / final assistant-text messages are NOT included
  (they're already in `sessions.messages`).

  No-op when the list is empty (a pure text turn with no tool calls).
  """
  @spec save_turn(String.t(), String.t(), integer(), [map()]) :: :ok
  def save_turn(_session_id, _user_id, _assistant_ts, []), do: :ok
  def save_turn(session_id, user_id, assistant_ts, tool_messages)
      when is_list(tool_messages) do
    try do
      existing = load(session_id)

      entry = %{
        "assistant_ts" => assistant_ts,
        "ts"           => System.os_time(:millisecond),
        "messages"     => Enum.map(tool_messages, &stringify_keys/1)
      }

      trimmed =
        (existing ++ [entry])
        |> cap_by_turns()
        |> cap_by_bytes()

      query!(Repo,
             "UPDATE sessions SET tool_history=? WHERE id=? AND user_id=?",
             [Jason.encode!(trimmed), session_id, user_id])
      :ok
    rescue
      e ->
        Logger.warning("[ToolHistory] save_turn failed: #{Exception.message(e)}")
        :ok
    end
  end

  @doc """
  Load the retained tool_history for a session. Returns a list of
  `%{"assistant_ts" => ts, "messages" => [...]}` maps. Empty on
  missing row, malformed JSON, or legacy rows without the column.
  """
  @spec load(String.t()) :: [map()]
  def load(session_id) do
    try do
      r = query!(Repo,
                 "SELECT tool_history FROM sessions WHERE id=?",
                 [session_id])

      case r.rows do
        [[nil]] -> []
        [[""]]  -> []
        [[json]] when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, list} when is_list(list) -> list
            _                               -> []
          end
        _ -> []
      end
    rescue
      _ -> []
    end
  end

  @doc """
  Interleave retained tool messages back into a text-only message
  history. For each assistant-role message in `history`, if its `ts`
  matches a tool_history entry's `assistant_ts`, insert that entry's
  tool messages IMMEDIATELY BEFORE the assistant message.

  This reconstructs the OpenAI-style message shape models expect:

      user
      assistant(tool_calls=[…])  ← from tool_history
      tool(tool_call_id=…)       ← from tool_history
      assistant(final text)       ← from session.messages

  Applies the byte budget from AgentSettings at retrieval time as a
  defensive second cap (in case the session has unusually large
  persisted entries).
  """
  @spec inject([map()], [map()]) :: [map()]
  def inject(history, tool_history) when is_list(history) and is_list(tool_history) do
    by_ts = Map.new(tool_history, fn e -> {Map.get(e, "assistant_ts"), e} end)

    budget = Dmhai.Agent.AgentSettings.tool_result_retention_bytes()
    {_budget_left, out} =
      Enum.reduce(history, {budget, []}, fn msg, {left, acc} ->
        ts   = msg[:ts] || msg["ts"]
        role = msg[:role] || msg["role"]

        case role == "assistant" and is_map(Map.get(by_ts, ts)) do
          true ->
            entry_msgs =
              by_ts
              |> Map.get(ts)
              |> Map.get("messages", [])
              |> Enum.map(&atomize_for_llm/1)

            size = Jason.encode!(entry_msgs) |> byte_size()

            cond do
              entry_msgs == [] ->
                {left, acc ++ [msg]}

              size <= left ->
                {left - size, acc ++ entry_msgs ++ [msg]}

              true ->
                # Over-budget entry dropped silently — older ones would be
                # trimmed first at save time, so this path is rare.
                {left, acc ++ [msg]}
            end

          false ->
            {left, acc ++ [msg]}
        end
      end)

    out
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp cap_by_turns(entries) do
    n = Dmhai.Agent.AgentSettings.tool_result_retention_turns()
    entries |> Enum.take(-n)
  end

  defp cap_by_bytes(entries) do
    cap = Dmhai.Agent.AgentSettings.tool_result_retention_bytes()

    # Walk newest → oldest, keeping entries while they fit; reverse at end.
    {kept, _} =
      entries
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn entry, {acc, used} ->
        entry_size = Jason.encode!(entry) |> byte_size()

        if used + entry_size <= cap do
          {[entry | acc], used + entry_size}
        else
          {acc, used}
        end
      end)

    kept
  end

  defp stringify_keys(msg) when is_map(msg) do
    msg
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  # Convert stored-as-strings JSON back into the atom-keyed shape the
  # LLM module expects (role, content, tool_calls, tool_call_id).
  defp atomize_for_llm(msg) when is_map(msg) do
    %{
      role:         msg["role"] || msg[:role],
      content:      msg["content"] || msg[:content] || "",
      tool_calls:   msg["tool_calls"] || msg[:tool_calls],
      tool_call_id: msg["tool_call_id"] || msg[:tool_call_id]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
