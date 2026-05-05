# Integration tests for `DmhAi.Agent.ToolMessageGrouper`.
# Run with: MIX_ENV=test mix test test/itgr_tool_message_grouper.exs
#
# These tests stress the partitioning + grouping invariants that
# `ToolHistory.save_tools_result_of_chain/4` depends on. The original
# bug (an Ollama "Not the same number of function calls and responses"
# crash) traced to the OLD positional pair_up logic dropping
# tool_results when an assistant message carried multiple tool_calls.
# The cases below cover every shape the chain accumulator can produce.

defmodule Itgr.ToolMessageGrouper do
  use ExUnit.Case, async: true

  alias DmhAi.Agent.ToolMessageGrouper

  defp asst(tcs) when is_list(tcs) do
    %{
      role: "assistant",
      content: "",
      tool_calls:
        Enum.map(tcs, fn {id, name} ->
          %{"id" => id, "function" => %{"name" => name, "arguments" => %{}}}
        end)
    }
  end

  defp tool(id, body \\ "ok"), do: %{role: "tool", tool_call_id: id, content: body}

  # ─── partition_into_call_blocks/1 ────────────────────────────────────────

  describe "partition_into_call_blocks/1" do
    test "empty input returns empty list" do
      assert ToolMessageGrouper.partition_into_call_blocks([]) == []
    end

    test "single 1-tc turn produces a single block with one tool_result" do
      msgs = [asst([{"a", "web_search"}]), tool("a")]
      [{a, ts}] = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert a.tool_calls |> hd() |> Map.get("id") == "a"
      assert length(ts) == 1
      assert hd(ts).tool_call_id == "a"
    end

    test "N parallel tcs in one assistant turn — ALL tool_results paired into one block" do
      msgs = [
        asst([{"a", "cancel_task"}, {"b", "create_task"}]),
        tool("a", "cancel ok"),
        tool("b", "create ok")
      ]

      [{a, ts}] = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert length(a.tool_calls) == 2
      assert length(ts) == 2
      ids = Enum.map(ts, & &1.tool_call_id) |> Enum.sort()
      assert ids == ["a", "b"]
    end

    test "two sequential 1-tc turns produce two distinct blocks" do
      msgs = [
        asst([{"a", "create_task"}]),
        tool("a", "task created"),
        asst([{"b", "web_search"}]),
        tool("b", "search results")
      ]

      blocks = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert length(blocks) == 2
      [{a1, [t1]}, {a2, [t2]}] = blocks
      assert hd(a1.tool_calls)["id"] == "a"
      assert t1.tool_call_id == "a"
      assert hd(a2.tool_calls)["id"] == "b"
      assert t2.tool_call_id == "b"
    end

    test "out-of-order tool_results within an N-tc block still pair correctly via id" do
      msgs = [
        asst([{"a", "cancel_task"}, {"b", "create_task"}]),
        tool("b", "create ok"),
        tool("a", "cancel ok")
      ]

      [{_, ts}] = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert length(ts) == 2
      # Tool messages stored in input (chain) order, not assistant-tcs order.
      assert Enum.map(ts, & &1.tool_call_id) == ["b", "a"]
    end

    test "orphan tool_result (no matching open assistant) is dropped" do
      msgs = [
        tool("orphan", "stray"),
        asst([{"a", "web_search"}]),
        tool("a", "ok")
      ]

      [{a, [t]}] = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert hd(a.tool_calls)["id"] == "a"
      assert t.tool_call_id == "a"
    end

    test "tool_result whose tool_call_id is unknown to the open block is dropped" do
      msgs = [
        asst([{"a", "web_search"}]),
        tool("xx", "wrong id"),
        tool("a", "right id")
      ]

      [{_, ts}] = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert length(ts) == 1
      assert hd(ts).tool_call_id == "a"
    end

    test "open block closes (with whatever it has) when a NEW assistant arrives without all tools matched" do
      # Defensive: in production the chain accumulator never drops
      # mid-block, but if it ever did, we'd rather emit a partial
      # block than hold one block open across an unrelated turn.
      msgs = [
        asst([{"a", "cancel_task"}, {"b", "create_task"}]),
        tool("a", "cancel ok"),
        # b's result is missing, then a NEW assistant turn arrives
        asst([{"c", "web_search"}]),
        tool("c", "search ok")
      ]

      blocks = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert length(blocks) == 2
      [{a1, [t1]}, {a2, [t2]}] = blocks
      assert length(a1.tool_calls) == 2
      assert t1.tool_call_id == "a"
      assert hd(a2.tool_calls)["id"] == "c"
      assert t2.tool_call_id == "c"
    end

    test "auto-pivot shape: model's compound + synthesised tcs in one assistant — every result preserved" do
      # The exact shape that motivated the rewrite: cancel_task
      # (model-emitted) + create_task (runtime-synthesised) packed
      # into one assistant turn, followed by both tool_results.
      msgs = [
        asst([
          {"sq5zDJyHG", "cancel_task"},
          {"YXV0b19waXZvdF8Tm5mVId4", "create_task"}
        ]),
        tool("sq5zDJyHG", ~s({"ok":true,"task_num":1})),
        tool("YXV0b19waXZvdF8Tm5mVId4", ~s({"ok":true,"task_num":2}))
      ]

      [{a, ts}] = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert length(a.tool_calls) == 2
      # CRITICAL: both tool_results must be in the block — losing
      # either is the bug that crashed Ollama on replay.
      assert length(ts) == 2
      ids = Enum.map(ts, & &1.tool_call_id) |> Enum.sort()
      assert ids == ["YXV0b19waXZvdF8Tm5mVId4", "sq5zDJyHG"]
    end

    test "string-keyed messages (post-JSON-decode shape) are handled" do
      msgs = [
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [%{"id" => "a", "function" => %{"name" => "x", "arguments" => %{}}}]
        },
        %{"role" => "tool", "tool_call_id" => "a", "content" => "ok"}
      ]

      [{a, [t]}] = ToolMessageGrouper.partition_into_call_blocks(msgs)
      assert hd(a["tool_calls"])["id"] == "a"
      assert t["tool_call_id"] == "a"
    end
  end

  # ─── group_blocks_by_task_num/2 ──────────────────────────────────────────

  describe "group_blocks_by_task_num/2" do
    test "empty input → empty output" do
      assert ToolMessageGrouper.group_blocks_by_task_num([], %{}) == []
    end

    test "single block tagged via stamps; messages flattened in order" do
      blocks = [
        {asst([{"a", "web_search"}]), [tool("a", "results")]}
      ]

      [{tn, msgs}] = ToolMessageGrouper.group_blocks_by_task_num(blocks, %{"a" => 7})
      assert tn == 7
      assert length(msgs) == 2
      assert hd(msgs).role == "assistant"
      assert Enum.at(msgs, 1).role == "tool"
    end

    test "consecutive blocks with the same task_num collapse into one entry" do
      blocks = [
        {asst([{"a", "web_search"}]), [tool("a")]},
        {asst([{"b", "extract_content"}]), [tool("b")]}
      ]

      [{tn, msgs}] = ToolMessageGrouper.group_blocks_by_task_num(blocks, %{"a" => 1, "b" => 1})
      assert tn == 1
      assert length(msgs) == 4
    end

    test "blocks with different task_nums produce separate entries" do
      blocks = [
        {asst([{"a", "cancel_task"}]), [tool("a")]},
        {asst([{"b", "web_search"}]), [tool("b")]}
      ]

      groups = ToolMessageGrouper.group_blocks_by_task_num(blocks, %{"a" => 1, "b" => 2})
      assert length(groups) == 2
      assert Enum.at(groups, 0) |> elem(0) == 1
      assert Enum.at(groups, 1) |> elem(0) == 2
    end

    test "missing stamp → entry tagged nil (legitimate free-mode tool use)" do
      blocks = [{asst([{"a", "web_search"}]), [tool("a")]}]
      [{tn, _}] = ToolMessageGrouper.group_blocks_by_task_num(blocks, %{})
      assert tn == nil
    end

    test "compound block (cancel_task + create_task) tagged by FIRST tc's task_num" do
      # The auto-pivot case. First tc is cancel_task on task 1; second
      # is the synthesised create_task on task 2. Whole block goes
      # under task 1 — when task 1's flush runs (immediately on
      # cancel), the block is archived under task 1. Acceptable.
      blocks = [
        {asst([{"a", "cancel_task"}, {"b", "create_task"}]), [tool("a"), tool("b")]}
      ]

      stamps = %{"a" => 1, "b" => 2}
      [{tn, msgs}] = ToolMessageGrouper.group_blocks_by_task_num(blocks, stamps)
      assert tn == 1
      assert length(msgs) == 3
      # Both tool_results MUST be in the messages list; losing the
      # second one was the original crash.
      tool_msgs = Enum.filter(msgs, &(&1.role == "tool"))
      assert length(tool_msgs) == 2
    end

    test "interleaved task_nums alternate group entries (no merge across boundary)" do
      blocks = [
        {asst([{"a", "x"}]), [tool("a")]},
        {asst([{"b", "y"}]), [tool("b")]},
        {asst([{"c", "z"}]), [tool("c")]}
      ]

      stamps = %{"a" => 1, "b" => 2, "c" => 1}
      groups = ToolMessageGrouper.group_blocks_by_task_num(blocks, stamps)
      # 3 groups: 1, 2, 1 — chunks_by stops merging at task_num boundary.
      assert Enum.map(groups, &elem(&1, 0)) == [1, 2, 1]
    end
  end
end
