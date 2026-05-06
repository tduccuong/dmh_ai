# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.ToolHistory do
  @moduledoc """
  Per-session rolling window of recent tool_call / tool_result message
  pairs. Lets the Assistant answer immediate follow-up questions
  ("what does section 3 of that PDF say?") without re-running the tool,
  while ageing out naturally so context can't grow unbounded.

  Storage: `sessions.tool_history` TEXT column holding a JSON array of
  entries:

      [
        {
          "assistant_ts": 1776940253417,  # ts of the chain's final-text assistant message
          "ts":           1776940253417,  # entry write time (== assistant_ts)
          "task_num":     7,              # task this group of pairs operated on (nil = free mode)
          "messages": [
            %{"role" => "assistant", "content" => "", "tool_calls" => [...]},
            %{"role" => "tool",      "content" => "...", "tool_call_id" => "..."},
            ...
          ]
        },
        ...
      ]

  ## Why entries are grouped by `task_num`, not by chain

  A single chain can span MULTIPLE tasks — the model can `cancel_task(N)`
  mid-chain, after which the runtime auto-creates a new task and the
  rest of the chain runs against it. Persisting the whole chain under
  ONE `task_num` would either be wrong (which one?) or null (the
  pre-#215.fix-A behavior — chain-end anchor was used; for chains that
  ended in `complete_task` the anchor reset to nil and the entry
  became unflushable).

  Fix: caller groups the chain's tool messages BY the task_num that
  was active when each (call, result) pair ran, then writes one
  entry per group. Each entry then has a definite `task_num` (or
  `nil` only for genuinely-free-mode tool use) and `flush_for_task/2`
  evicts cleanly when the matching task closes.

  ## Invariant: rolling window holds only OPEN-task or FREE-mode work

  The window's purpose is "context for follow-ups on what the user is
  *currently* working on." Once a task closes, its tool work belongs
  in the archive (`task_chain_archive`), not the rolling window —
  otherwise every closed task keeps paying LLM context-rent until cap
  eviction, and `fetch_task(N)` becomes the *only* safe answer source
  for any closed-task question (since the model can't tell stale
  rolling-window data apart from current).

  `save_tools_result_of_chain/4` enforces this on every write: groups
  whose `task_num` is currently in `done|cancelled|paused` skip the
  rolling window and route straight to `TaskChainArchive.append_raw/3`.
  Groups for `ongoing` tasks or with `task_num: nil` (free-mode tool
  use) append to the rolling window normally.

  This complements the mid-chain `flush_for_task/2` call from
  `Tasks.mark_{done,cancelled,paused}/1`. Without the save-time filter,
  the chain-end finalise would re-introduce the just-flushed task's
  data on every close.

  ## Caps (applied on every save to the rolling window)

    * **Turn cap** — keep at most
      `AgentSettings.tool_result_retention_turns/0` most-recent
      entries (default 5).
    * **Byte cap** — if the combined JSON size of retained entries
      exceeds `AgentSettings.tool_result_retention_bytes/0` (default
      120_000 bytes), drop oldest-first until it fits.

  Both caps drop WHOLE entries; tool-result bodies are never
  truncated. Evicted entries with a `task_num` get archived to
  `task_chain_archive` so `fetch_task(N)` can still retrieve them.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Persist the tool_call / tool_result messages produced by a single
  chain. The chain's pairs are pre-split into per-`task_num` groups by
  the caller (see `UserAgent.execute_tools/3`); this function writes
  one tool_history entry per group, then applies the rolling caps.

  `groups` is a list of `{task_num, messages}` tuples:

    - `task_num` is the integer the call operated on, or `nil` for
      free-mode tool use (no active task — legitimate, but the entry
      is then NOT recoverable via `fetch_task`).
    - `messages` is the alternating
      `[assistant_with_tool_calls, tool_result, assistant_with_tool_calls, tool_result, …]`
      list for that group.

  Empty groups (after `fetch_task` pair-stripping) are skipped. If
  every group is empty (a pure-text chain), this is a no-op.

  Both caps and per-task archival on eviction run after all groups
  are appended — not per-group — so eviction order matches age
  consistently.
  """
  @spec save_tools_result_of_chain(
          String.t(),
          String.t(),
          integer(),
          [{integer() | nil, [map()]}]
        ) :: :ok
  def save_tools_result_of_chain(session_id, user_id, assistant_ts, groups)
      when is_binary(session_id) and is_binary(user_id) and is_integer(assistant_ts) and
             is_list(groups) do
    cleaned =
      Enum.flat_map(groups, fn {task_num, msgs} ->
        case strip_fetch_task_pairs(msgs) do
          [] -> []
          kept -> [{task_num, kept}]
        end
      end)

    # Partition by task status. Closed tasks (`done|cancelled|paused`)
    # never enter the rolling window — their messages route straight
    # to `task_chain_archive` so `fetch_task(N)` can still retrieve
    # them, while the LLM's context on the next chain stays free of
    # closed-task data. See the moduledoc invariant.
    {to_rolling, to_archive_only} =
      Enum.split_with(cleaned, fn {task_num, _msgs} ->
        not closed_task?(session_id, task_num)
      end)

    Enum.each(to_archive_only, fn {task_num, msgs} ->
      archive_closed_group(session_id, task_num, msgs)
    end)

    if to_rolling == [] do
      :ok
    else
      try do
        existing = load(session_id)

        new_entries =
          Enum.map(to_rolling, fn {task_num, msgs} ->
            %{
              "assistant_ts" => assistant_ts,
              "ts" => System.os_time(:millisecond),
              "task_num" => task_num,
              "messages" => Enum.map(msgs, &stringify_keys/1)
            }
          end)

        appended = existing ++ new_entries
        {trimmed, evicted} = cap_and_split(appended)

        archive_evicted(evicted, session_id)

        query!(
          Repo,
          "UPDATE sessions SET tool_history=? WHERE id=? AND user_id=?",
          [Jason.encode!(trimmed), session_id, user_id]
        )

        :ok
      rescue
        e ->
          Logger.warning(
            "[ToolHistory] save_tools_result_of_chain failed: #{Exception.message(e)}"
          )

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
      messages
      |> Enum.flat_map(fn msg ->
        cond do
          tool_result_for?(msg, fetch_ids) ->
            []

          assistant_with_tool_calls?(msg) ->
            kept =
              msg
              |> tool_calls_of()
              |> Enum.reject(&MapSet.member?(fetch_ids, tc_id(&1)))

            cond do
              kept == [] -> []
              true -> [put_tool_calls(msg, kept)]
            end

          true ->
            [msg]
        end
      end)
    end
  end

  defp tool_calls_of(msg), do: Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") || []

  defp tc_id(tc), do: Map.get(tc, :id) || Map.get(tc, "id")

  defp fetch_task?(tc) do
    fn_map = Map.get(tc, :function) || Map.get(tc, "function") || %{}
    name = Map.get(fn_map, :name) || Map.get(fn_map, "name")
    name == "fetch_task"
  end

  defp tool_result_for?(msg, ids) do
    role = Map.get(msg, :role) || Map.get(msg, "role")
    id = Map.get(msg, :tool_call_id) || Map.get(msg, "tool_call_id")
    role == "tool" and is_binary(id) and MapSet.member?(ids, id)
  end

  defp assistant_with_tool_calls?(msg) do
    role = Map.get(msg, :role) || Map.get(msg, "role")
    tcs = tool_calls_of(msg)
    role == "assistant" and is_list(tcs) and tcs != []
  end

  defp put_tool_calls(msg, tcs) do
    cond do
      Map.has_key?(msg, :tool_calls) -> Map.put(msg, :tool_calls, tcs)
      true -> Map.put(msg, "tool_calls", tcs)
    end
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

  defp cap_by_turns(list) do
    cap = DmhAi.Agent.AgentSettings.tool_result_retention_turns()

    if length(list) > cap do
      Enum.take(list, -cap)
    else
      list
    end
  end

  defp cap_by_bytes(list) do
    cap = DmhAi.Agent.AgentSettings.tool_result_retention_bytes()
    do_cap_by_bytes(list, cap)
  end

  defp do_cap_by_bytes([], _cap), do: []

  defp do_cap_by_bytes(list, cap) do
    encoded = Jason.encode!(list)

    if byte_size(encoded) <= cap do
      list
    else
      do_cap_by_bytes(tl(list), cap)
    end
  end

  # Is the task at `(session_id, task_num)` currently in a closed
  # state (`done`, `cancelled`, `paused`)? Used by
  # `save_tools_result_of_chain/4` to decide whether to admit a group
  # to the rolling window or archive it directly. `nil` task_num
  # (free-mode tool use) is NOT closed — it has no task to be closed.
  defp closed_task?(_session_id, nil), do: false

  defp closed_task?(session_id, task_num) when is_integer(task_num) do
    case DmhAi.Agent.Tasks.resolve_num(session_id, task_num) do
      {:ok, task_id} ->
        case DmhAi.Agent.Tasks.get(task_id) do
          %{task_status: status} when status in ["done", "cancelled", "paused"] -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # Route a closed-task chain group straight to `task_chain_archive`
  # without ever entering the rolling window. Same archive path that
  # `flush_for_task/2` and the cap-eviction sweep use.
  defp archive_closed_group(session_id, task_num, msgs) when is_integer(task_num) do
    case DmhAi.Agent.Tasks.resolve_num(session_id, task_num) do
      {:ok, task_id} ->
        DmhAi.Agent.TaskChainArchive.append_raw(
          task_id,
          session_id,
          Enum.map(msgs, &stringify_keys/1)
        )

      _ ->
        Logger.warning(
          "[ToolHistory] save: closed task_num=#{task_num} not resolvable in session=#{session_id}; dropping group without archival"
        )
    end
  end

  defp archive_closed_group(_session_id, _task_num, _msgs), do: :ok

  defp archive_evicted([], _session_id), do: :ok

  defp archive_evicted(entries, session_id) do
    Enum.each(entries, fn entry ->
      case Map.get(entry, "task_num") do
        n when is_integer(n) ->
          case DmhAi.Agent.Tasks.resolve_num(session_id, n) do
            {:ok, task_id} ->
              msgs = Map.get(entry, "messages") || []
              DmhAi.Agent.TaskChainArchive.append_raw(task_id, session_id, msgs)

            {:error, :not_found} ->
              Logger.warning(
                "[ToolHistory] evicted entry's task_num=#{n} no longer exists in session=#{session_id}; dropping without archival"
              )
          end

        _ ->
          # Free-mode tool use without a task — no archival, just drop.
          :ok
      end
    end)
  end

  @doc """
  Move every retained tool_history entry whose `task_num` matches
  from `sessions.tool_history` into `task_chain_archive`. Called by
  `Tasks.mark_done/2` and `Tasks.mark_cancelled/2` immediately after
  the status flip — completed work no longer ships to the LLM on
  subsequent chains, while remaining recoverable via `fetch_task(N)`
  from the archive.

  Same archive path as eviction (`TaskChainArchive.append_raw`), so
  ordering and shape match.

  No-op when `task_num` is nil (free-mode tool use). No-op when
  nothing in the rolling window matches.
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
        case DmhAi.Agent.Tasks.resolve_num(session_id, task_num) do
          {:ok, task_id} ->
            Enum.each(to_archive, fn entry ->
              msgs = Map.get(entry, "messages") || []
              DmhAi.Agent.TaskChainArchive.append_raw(task_id, session_id, msgs)
            end)

          {:error, :not_found} ->
            Logger.warning(
              "[ToolHistory] flush_for_task: task_num=#{task_num} not found in session=#{session_id}; entries dropped without archival"
            )
        end

        query!(
          Repo,
          "UPDATE sessions SET tool_history=? WHERE id=?",
          [Jason.encode!(retained), session_id]
        )
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
  `task_num` matches. Used by `fetch_task(N)` to surface in-flight
  tool data for the named task. Multiple entries may match (one
  chain can produce N entries via per-task grouping); they are
  returned in chain-write order.
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
  `%{"assistant_ts" => ts, "task_num" => N | nil, "messages" => [...]}`
  maps. Empty on missing row, malformed JSON, or rows with a null
  column.
  """
  @spec load(String.t()) :: [map()]
  def load(session_id) do
    try do
      r =
        query!(
          Repo,
          "SELECT tool_history FROM sessions WHERE id=?",
          [session_id]
        )

      case r.rows do
        [[nil]] ->
          []

        [[""]] ->
          []

        [[json]] when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  @doc """
  Interleave retained tool messages back into a text-only message
  history. For each assistant-role message in `history`, if its `ts`
  matches one or more tool_history entries' `assistant_ts`, insert
  ALL those entries' tool messages (concatenated, in stored order)
  immediately before the assistant message.

  Why "one or more": after the per-task grouping change, a single
  chain can produce multiple tool_history entries with the SAME
  `assistant_ts` (one per task_num group). The injector merges them
  back so the model sees the complete OpenAI-style sequence:

      user
      assistant(tool_calls=[…])  ← from tool_history (group A)
      tool(tool_call_id=…)       ← from tool_history (group A)
      assistant(tool_calls=[…])  ← from tool_history (group B)
      tool(tool_call_id=…)       ← from tool_history (group B)
      assistant(final text)       ← from session.messages

  Applies the byte budget from AgentSettings at retrieval time as a
  defensive second cap (in case the session has unusually large
  persisted entries).
  """
  @spec inject([map()], [map()]) :: [map()]
  def inject(history, tool_history) when is_list(history) and is_list(tool_history) do
    by_ts =
      Enum.group_by(tool_history, fn e -> Map.get(e, "assistant_ts") end)

    budget = DmhAi.Agent.AgentSettings.tool_result_retention_bytes()

    {_budget_left, out} =
      Enum.reduce(history, {budget, []}, fn msg, {left, acc} ->
        ts = msg[:ts] || msg["ts"]
        role = msg[:role] || msg["role"]
        matched_entries = Map.get(by_ts, ts, [])

        case role == "assistant" and matched_entries != [] do
          true ->
            entry_msgs =
              matched_entries
              |> Enum.flat_map(fn e -> Map.get(e, "messages", []) end)
              |> Enum.map(&atomize_for_llm/1)

            size = Jason.encode!(entry_msgs) |> byte_size()

            cond do
              entry_msgs == [] ->
                {left, acc ++ [msg]}

              size <= left ->
                {left - size, acc ++ entry_msgs ++ [msg]}

              true ->
                # Entry block alone exceeds remaining budget — skip
                # injection for this assistant turn. The text-only
                # assistant message still ships; the tool details are
                # missing for this turn but earlier turns kept theirs.
                {left, acc ++ [msg]}
            end

          false ->
            {left, acc ++ [msg]}
        end
      end)

    out
  end

  # Stringify keys for JSON storage. Map values are passed through
  # verbatim — assumed to be JSON-encodable already (they came from
  # the LLM message accumulator which is JSON-friendly by
  # construction).
  defp stringify_keys(msg) when is_map(msg) do
    Map.new(msg, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Atom-key the JSON-stored message so the LLM adapter normalisers
  # accept it. Handles both ":role"/":content" and shapes nested
  # under "tool_calls".
  defp atomize_for_llm(msg) when is_map(msg) do
    Map.new(msg, fn
      {"role", v} -> {:role, v}
      {"content", v} -> {:content, v}
      {"tool_calls", v} -> {:tool_calls, v}
      {"tool_call_id", v} -> {:tool_call_id, v}
      {k, v} -> {k, v}
    end)
  end
end
