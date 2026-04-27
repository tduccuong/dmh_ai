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
  Record a chain's tool messages against its final-assistant ts, then
  trim to the configured turn + byte caps. Entries that roll out of
  retention via `cap_by_turns` / `cap_by_bytes` are archived to
  `task_turn_archive` if the chain was tagged with a `task_num`.
  See architecture.md §Task state continuity across chains.

  `tool_messages` is the subset of the chain's in-memory message list
  that has role="assistant" with tool_calls, or role="tool" with a
  tool_call_id. User / final assistant-text messages are NOT included
  (they're already in `sessions.messages`).

  `task_num` (optional) tags this chain's tool messages so `fetch_task`
  can find them. `nil` → untagged; the entry rolls out normally
  without archival when retention trims.

  No-op when the list is empty (a pure text chain with no tool calls).
  """
  @spec save_turn(String.t(), String.t(), integer(), [map()], integer() | nil) :: :ok
  def save_turn(session_id, user_id, assistant_ts, tool_messages, task_num \\ nil)
  def save_turn(_session_id, _user_id, _assistant_ts, [], _task_num), do: :ok
  def save_turn(session_id, user_id, assistant_ts, tool_messages, task_num)
      when is_list(tool_messages) do
    # Strip any fetch_task tool_call / tool_result pairs — its result
    # body is a snapshot of another task's archive, already stored in
    # that task's task_turn_archive row. Persisting it again here
    # would duplicate bytes for no model-visible benefit. See
    # architecture.md §Tool-result retention.
    case strip_fetch_task_pairs(tool_messages) do
      [] ->
        :ok

      stripped ->
        try do
          existing = load(session_id)

          entry = %{
            "assistant_ts" => assistant_ts,
            "ts"           => System.os_time(:millisecond),
            "task_num"     => task_num,
            "messages"     => Enum.map(stripped, &stringify_keys/1)
          }

          appended = existing ++ [entry]
          {trimmed, evicted} = cap_and_split(appended)

          # Archive evicted entries that carry a task_num.
          archive_evicted(evicted, session_id)

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
  end

  # Two-pass scrub: collect every fetch_task tool_call's id, then drop
  # both (a) the assistant message's fetch_task tool_call entries
  # (preserving siblings — multi-batch turns are common) and (b) the
  # corresponding tool-result messages. An assistant message whose
  # tool_calls list becomes empty after filtering is dropped entirely.
  # Accepts both atom-keyed and string-keyed maps (chain accumulator vs.
  # JSON-decoded shapes both flow through here at different times).
  defp strip_fetch_task_pairs([]), do: []
  defp strip_fetch_task_pairs(messages) do
    fetch_ids =
      messages
      |> Enum.flat_map(fn m -> tool_calls_of(m) end)
      |> Enum.filter(&fetch_task?/1)
      |> Enum.map(&tc_id/1)
      |> MapSet.new()

    if MapSet.size(fetch_ids) == 0 do
      messages
    else
      Enum.flat_map(messages, fn m -> strip_message(m, fetch_ids) end)
    end
  end

  defp strip_message(m, fetch_ids) do
    case role_of(m) do
      "tool" ->
        if MapSet.member?(fetch_ids, Map.get(m, :tool_call_id) || Map.get(m, "tool_call_id")) do
          []
        else
          [m]
        end

      "assistant" ->
        tcs = tool_calls_of(m)
        remaining = Enum.reject(tcs, fn tc -> MapSet.member?(fetch_ids, tc_id(tc)) end)

        cond do
          length(remaining) == length(tcs) -> [m]
          remaining == [] -> []
          true ->
            [m
             |> Map.put(:tool_calls, remaining)
             |> Map.put("tool_calls", remaining)]
        end

      _ ->
        [m]
    end
  end

  defp role_of(m), do: Map.get(m, :role) || Map.get(m, "role")

  defp tool_calls_of(m), do: Map.get(m, :tool_calls) || Map.get(m, "tool_calls") || []

  defp tc_id(tc), do: Map.get(tc, :id) || Map.get(tc, "id")

  defp fetch_task?(tc) do
    fn_map = Map.get(tc, :function) || Map.get(tc, "function") || %{}
    name   = Map.get(fn_map, :name) || Map.get(fn_map, "name")
    name == "fetch_task"
  end

  # Apply both caps and return the retained list AND the list of
  # entries that were dropped (so we can archive them by task_num).
  defp cap_and_split(list) do
    after_turn_cap = cap_by_turns(list)
    dropped_by_turn = Enum.drop(list, length(after_turn_cap))

    after_byte_cap = cap_by_bytes(after_turn_cap)
    dropped_by_byte = Enum.take(after_turn_cap, length(after_turn_cap) - length(after_byte_cap))

    {after_byte_cap, dropped_by_turn ++ dropped_by_byte}
  end

  defp archive_evicted([], _session_id), do: :ok
  defp archive_evicted(entries, session_id) do
    Enum.each(entries, fn entry ->
      case Map.get(entry, "task_num") do
        n when is_integer(n) ->
          case Dmhai.Agent.Tasks.resolve_num(session_id, n) do
            {:ok, task_id} ->
              msgs = Map.get(entry, "messages") || []
              Dmhai.Agent.TaskTurnArchive.append_raw(task_id, session_id, msgs)

            {:error, :not_found} ->
              Logger.warning("[ToolHistory] evicted entry's task_num=#{n} no longer exists in session=#{session_id}; dropping without archival")
          end

        _ ->
          # Untagged chain (free-mode tool use without a task) — no
          # archival, just drop.
          :ok
      end
    end)
  end

  @doc """
  Move every retained tool_history entry whose `task_num` matches
  from `sessions.tool_history` into `task_turn_archive`. Called by
  `Tasks.mark_done/2` and `Tasks.mark_cancelled/2` immediately after
  the status flip — completed work no longer ships to the LLM on
  subsequent chains, while remaining recoverable via `fetch_task(N)`
  from the archive. See architecture.md §Tool-result retention.

  Same archive path as eviction (`TaskTurnArchive.append_raw`), so
  ordering and shape match.

  No-op when `task_num` is nil (some periodics resolve at chain end
  with an `anchor_task_num=nil` ctx — defensive). No-op when nothing
  in the rolling window matches.
  """
  @spec flush_for_task(String.t(), integer() | nil) :: :ok
  def flush_for_task(_session_id, nil), do: :ok
  def flush_for_task(session_id, task_num) when is_integer(task_num) do
    try do
      existing = load(session_id)

      {to_archive, retained} =
        Enum.split_with(existing, fn entry ->
          Map.get(entry, "task_num") == task_num
        end)

      if to_archive != [] do
        case Dmhai.Agent.Tasks.resolve_num(session_id, task_num) do
          {:ok, task_id} ->
            Enum.each(to_archive, fn entry ->
              msgs = Map.get(entry, "messages") || []
              Dmhai.Agent.TaskTurnArchive.append_raw(task_id, session_id, msgs)
            end)

          {:error, :not_found} ->
            Logger.warning("[ToolHistory] flush_for_task: task_num=#{task_num} not found in session=#{session_id}; entries dropped without archival")
        end

        query!(Repo,
               "UPDATE sessions SET tool_history=? WHERE id=?",
               [Jason.encode!(retained), session_id])
      end

      :ok
    rescue
      e ->
        Logger.warning("[ToolHistory] flush_for_task failed: #{Exception.message(e)}")
        :ok
    end
  end

  @doc """
  Return the subset of the session's retained tool_history whose
  `task_num` field matches — i.e. chains that operated on this task
  and are still in retention. Used by `fetch_task` to surface prior
  tool outputs for a task without dragging in unrelated chains'
  outputs. See architecture.md §Task state continuity across chains.
  """
  @spec load_for_task_num(String.t(), integer()) :: [map()]
  def load_for_task_num(session_id, task_num)
      when is_binary(session_id) and is_integer(task_num) do
    session_id
    |> load()
    |> Enum.filter(fn entry -> Map.get(entry, "task_num") == task_num end)
  end

  @doc """
  Load the retained tool_history for a session. Returns a list of
  `%{"assistant_ts" => ts, "messages" => [...]}` maps. Empty on
  missing row, malformed JSON, or rows with a null column.
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
