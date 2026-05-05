# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.ToolMessageGrouper do
  @moduledoc """
  Partitioning of a chain's tool-message stream into call blocks
  and per-task groups, ready for `ToolHistory.save_tools_result_of_chain/4`.

  ## Why this module exists

  The naive approach — pair messages by their position in the stream
  (`[asst, tool, asst, tool, ...]` alternation) — is wrong for any
  legal OpenAI tool-call shape that isn't strict 1-tc-per-assistant:

    * **N parallel `tool_calls` in one assistant turn** — one assistant
      message followed by N tool messages.
    * **Runtime-synthesised assistant turns** — e.g. the auto-pivot's
      injected `create_task` — sit inside the same chain alongside
      the model's own turns; positional pairing collapses them.
    * **Compound assistant tool_calls** — when both the model's call
      and a runtime-synthesised call land in the SAME assistant
      message (the bug that motivated this rewrite), the message
      carries multiple tool_call ids whose results follow in order.

  The fix: walk the stream as a state machine that opens a block on
  every assistant-with-tool_calls and closes it when ALL of its
  tool_call ids have matching tool messages — matched **by
  tool_call_id, not by position**. This is robust to:

    * single tc per assistant (common),
    * N parallel tcs in one assistant turn,
    * out-of-order tool results within a turn (defensive — should not
      happen, but the id-based match is order-agnostic),
    * synthetic assistant injections interleaved with the model's,
    * orphan tool results with no matching open assistant — silently
      dropped (the alternative is a half-formed block that breaks
      the OpenAI/Ollama count-check on replay and crashes the
      next chain).

  ## Two-step flow

      messages
      |> partition_into_call_blocks()
      #=> [{assistant_msg, [tool_msgs]}, ...]
      |> group_blocks_by_task_num(stamps)
      #=> [{task_num, [message]}]                  # ready for ToolHistory.save_tools_result_of_chain/4

  Step 1 makes blocks. Step 2 attributes each block to a task and
  merges consecutive same-task blocks into one entry's messages list.

  ## Multi-task assistant blocks

  When the auto-pivot fires, the resulting assistant message can
  carry tool_calls spanning multiple tasks (`cancel_task(N)` +
  synthesised `create_task(M)`). Such a block is tagged with the
  first tool_call's task_num. The whole block flushes together
  under that task — acceptable because the new task gets a fresh
  start and doesn't need the cancelled task's tail bleeding in.

  Splitting one assistant message into per-tc sub-messages was
  considered and rejected: it would mutate the wire shape on
  replay (one assistant turn would re-appear as N separate turns,
  changing the conversation the LLM sees).
  """

  @typedoc "An assistant message with tool_calls plus the matching tool results, in input order."
  @type call_block :: {map(), [map()]}

  @doc """
  Walk a stream of `assistant`/`tool` messages and partition it into
  call blocks. Each block pairs ONE assistant message with the tool
  messages whose `tool_call_id` matches one of the assistant's
  `tool_calls[].id`.

  Pairing is by id, not position, so any legal interleaving of
  parallel-tc assistants, runtime-synthesised assistants, and
  out-of-order tool results works correctly.

  Returns `[]` when the input is empty or contains no assistant-
  with-tool_calls messages.
  """
  @spec partition_into_call_blocks([map()]) :: [call_block]
  def partition_into_call_blocks([]), do: []
  def partition_into_call_blocks(msgs) when is_list(msgs), do: walk(msgs, nil, [])

  @doc """
  Tag each block with the `task_num` stamped against its assistant's
  first `tool_call_id` (looked up in `stamps`), then merge
  consecutive same-task blocks into one entry's messages list.

  `stamps` is the `%{tool_call_id => task_num}` map built by
  `UserAgent.stamp_tool_call_task_num/4` during `execute_tools/3`.
  Missing stamps yield `task_num: nil` (free-mode tool use — the
  entry is then not flushable per-task and ages out via the rolling
  retention cap, which is the legitimate fallback).

  Returns `[]` for an empty block list. Otherwise returns
  `[{task_num, [message]}]` in chain order, ready to hand to
  `ToolHistory.save_tools_result_of_chain/4`.
  """
  @spec group_blocks_by_task_num([call_block], %{optional(String.t()) => integer() | nil}) ::
          [{integer() | nil, [map()]}]
  def group_blocks_by_task_num([], _stamps), do: []

  def group_blocks_by_task_num(blocks, stamps) when is_list(blocks) and is_map(stamps) do
    blocks
    |> Enum.map(fn {a, ts} -> {Map.get(stamps, first_tool_call_id(a)), {a, ts}} end)
    |> Enum.chunk_by(fn {tn, _} -> tn end)
    |> Enum.map(fn chunk ->
      {task_num, _} = hd(chunk)
      msgs = Enum.flat_map(chunk, fn {_, {a, ts}} -> [a | ts] end)
      {task_num, msgs}
    end)
  end

  # ─── walker ──────────────────────────────────────────────────────────────

  # State variants:
  #   `nil`                 — no open block; stray tool messages are dropped.
  #   `%{msg, want, got}`   — open block;
  #                           `want` is the still-unmatched MapSet of tool_call_ids,
  #                           `got`  is the list of matched tool messages so far.
  defp walk([], nil, acc), do: Enum.reverse(acc)
  defp walk([], pending, acc), do: Enum.reverse([finalise_block(pending) | acc])

  defp walk([msg | rest], pending, acc) do
    cond do
      assistant_with_tool_calls?(msg) ->
        # Opening a new block. If a prior block was still open
        # (incomplete tool results), close it as-is — emitting a
        # partial block matches the wire-spec invariant for what we
        # actually have, and is better than holding it open across
        # an unrelated assistant turn.
        acc = close_pending(pending, acc)

        wanted =
          msg
          |> tool_calls_of()
          |> Enum.map(&tool_call_id/1)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        walk(rest, %{msg: msg, want: wanted, got: []}, acc)

      tool_result?(msg) and is_map(pending) ->
        tcid = tool_result_id(msg)

        cond do
          tcid != nil and MapSet.member?(pending.want, tcid) ->
            new_want = MapSet.delete(pending.want, tcid)
            new_got = pending.got ++ [msg]

            if MapSet.size(new_want) == 0 do
              walk(rest, nil, [{pending.msg, new_got} | acc])
            else
              walk(rest, %{pending | want: new_want, got: new_got}, acc)
            end

          true ->
            # Tool result whose tool_call_id is NOT in the open
            # block's wanted set. Drop — keeping it would either
            # corrupt the block or force us to open a fake assistant.
            walk(rest, pending, acc)
        end

      true ->
        # Anything that isn't an assistant-with-tool_calls or a
        # matching tool_result: stray. The collect_tool_messages/1
        # filter upstream should have removed these, but if any leak
        # through, drop without disturbing the open block.
        walk(rest, pending, acc)
    end
  end

  defp close_pending(nil, acc), do: acc
  defp close_pending(pending, acc), do: [finalise_block(pending) | acc]
  defp finalise_block(%{msg: m, got: g}), do: {m, g}

  # ─── shape helpers ───────────────────────────────────────────────────────

  defp assistant_with_tool_calls?(m) do
    role = m[:role] || m["role"]
    tcs = tool_calls_of(m)
    role == "assistant" and is_list(tcs) and tcs != []
  end

  defp tool_result?(m) do
    role = m[:role] || m["role"]
    id = m[:tool_call_id] || m["tool_call_id"]
    role == "tool" and is_binary(id) and id != ""
  end

  defp tool_calls_of(m), do: m[:tool_calls] || m["tool_calls"] || []
  defp tool_call_id(tc), do: Map.get(tc, "id") || Map.get(tc, :id)
  defp tool_result_id(m), do: m[:tool_call_id] || m["tool_call_id"]

  defp first_tool_call_id(msg) do
    case tool_calls_of(msg) do
      [tc | _] -> tool_call_id(tc)
      _ -> nil
    end
  end
end
