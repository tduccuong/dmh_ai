# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F09 — Task with web research (web_search + extract_content).
#
# Two-tool task chain in assistant mode:
#
#   create_task("research X")
#     → web_search(query)        — survey results
#     → extract_content(path/url) — deep-read the most relevant hit
#     → complete_task(answer)    — synthesise and close
#
# Same overall shape as F07 (one_off task chain) but with TWO
# orthogonal tools faked via `T.stub_tool/1`. Locks in:
#
#   * `web_search` and `extract_content` BOTH dispatch through
#     `Tools.Registry.execute/3` and so are interceptable via the
#     same hook (the hook is per-tool-name, not per-call-shape).
#   * Every tool's `tool_call_id` round-trips into its tool_result,
#     and the chain's tool_history archive at `complete_task` time
#     carries both pairs (assistant↔web_search + assistant↔extract_content).
#   * All tool progress rows for non-`complete_task` verbs stay
#     visible (the FE shows the model's investigative steps as
#     individual bubbles).

defmodule DmhAi.Flows.F09TaskWithWebResearch do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{Tasks, TaskChainArchive}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F09"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F09")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
       System.os_time(:millisecond)])

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [session_id, user_id, "assistant", "[]", "[]",
       System.os_time(:millisecond), System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM session_progress WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM task_chain_archive WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "create_task → web_search → extract_content → complete_task closes the task with archived pairs",
       %{user_id: user_id, session_id: session_id} do
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

    # Stub web_search and extract_content. Other tools (create_task,
    # complete_task) hit the real Registry path.
    web_search_calls = :counters.new(1, [:atomics])
    extract_calls    = :counters.new(1, [:atomics])

    T.stub_tool(fn name, args, _ctx ->
      case name do
        "web_search" ->
          :counters.add(web_search_calls, 1, 1)
          query = args["query"] || args[:query] || ""
          {:ok,
           "Search results for #{inspect(query)}:\n" <>
             "1. https://example.test/eiffel-tower-overview — Eiffel Tower overview\n" <>
             "2. https://example.test/iron-content — Iron content of the tower\n" <>
             "3. https://example.test/yearly-paint — Yearly paint maintenance\n"}

        "extract_content" ->
          :counters.add(extract_calls, 1, 1)
          path = args["path"] || args[:path] || ""
          {:ok,
           "[stubbed extract_content from #{path}]\n" <>
             "The Eiffel Tower contains approximately 7,300 metric tons of " <>
             "puddled iron. Construction completed 1889; height 330m incl. antennas.\n"}

        _other ->
          :passthrough
      end
    end)

    create_call_id   = "ct-1"
    search_call_id   = "ws-1"
    extract_call_id  = "ec-1"
    complete_call_id = "cp-1"

    [obs] =
      T.session_walk(user_id, session_id, [
        {"how much iron is in the Eiffel Tower?",
         [
           # Turn 0 — open a task for the research.
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => create_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "create_task",
                   "arguments" => %{
                     "task_type"  => "one_off",
                     "task_title" => "Eiffel Tower iron content",
                     "task_spec"  => "find the iron tonnage of the Eiffel Tower",
                     "language"   => "en"
                   }
                 }}]}
           end,

           # Turn 1 — web search to survey results.
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => search_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "web_search",
                   "arguments" => %{"query" => "Eiffel Tower iron tonnage"}
                 }}]}
           end,

           # Turn 2 — deep-read the most relevant hit.
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => extract_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "extract_content",
                   "arguments" => %{"path" => "https://example.test/iron-content"}
                 }}]}
           end,

           # Turn 3 — synthesise and close.
           fn _msgs, _tools ->
             {:tool_calls,
              [%{"id" => complete_call_id,
                 "type" => "function",
                 "function" => %{
                   "name" => "complete_task",
                   "arguments" => %{
                     "task_num"    => 1,
                     "task_result" => "≈7,300 t puddled iron"
                   }
                 }}]}
           end,

           # Turn 4 — delivery turn (complete_task fired with empty
           # narration, runtime falls through one more LLM round-trip).
           fn _msgs, _tools ->
             {:text,
              "The Eiffel Tower contains approximately 7,300 metric tons of " <>
                "puddled iron — figured by extracting the iron-content article " <>
                "from the search results."}
           end
         ]}
      ])

    # ── Assertions ────────────────────────────────────────────────

    # 1. Both stubbed tools were hit exactly once.
    assert :counters.get(web_search_calls, 1) == 1,
           "web_search should be hit exactly once; got: #{:counters.get(web_search_calls, 1)}"
    assert :counters.get(extract_calls, 1) == 1,
           "extract_content should be hit exactly once; got: #{:counters.get(extract_calls, 1)}"

    # 2. Task closed.
    [task] = Tasks.list_for_session(session_id)
    assert task.task_status == "done"
    assert task.task_result =~ "7,300" or task.task_result =~ "puddled iron",
           "task_result should reflect the synthesised answer; got: #{inspect(task.task_result)}"

    # 3. Archive carries BOTH tool pairs (web_search + extract_content)
    #    plus the assistant tool_call shells. complete_task is a
    #    bookkeeping verb — its result row is also archived but its
    #    progress row is hidden (per F07's contract).
    archive = TaskChainArchive.fetch_for_task(task.task_id)
    refute archive == [], "archive should be populated after complete_task"

    archive_dump =
      Enum.map_join(archive, "\n", fn r -> to_string(Map.get(r, :content) || "") end)

    assert archive_dump =~ "Search results",
           "archive should contain the web_search result; got: #{inspect(archive_dump)}"
    assert archive_dump =~ "puddled iron",
           "archive should contain the extract_content result; got: #{inspect(archive_dump)}"

    # tool_call_ids round-trip via the assistant rows' tool_calls list.
    archive_calls =
      archive
      |> Enum.flat_map(fn r ->
           Map.get(r, :tool_calls) ||
             (case Map.get(r, :tool_calls_json) do
                nil -> []
                json -> Jason.decode!(json)
              end)
         end)

    archive_call_ids =
      archive_calls
      |> Enum.map(fn tc -> tc["id"] || tc[:id] end)
      |> MapSet.new()

    # `complete_task`'s tool_call should also be present in the archive,
    # but the assertion that matters is the two investigative tools
    # whose results carry data the model uses.
    assert MapSet.member?(archive_call_ids, search_call_id),
           "archive should carry the web_search tool_call shell (id=#{search_call_id}); got ids: #{inspect(MapSet.to_list(archive_call_ids))}"
    assert MapSet.member?(archive_call_ids, extract_call_id),
           "archive should carry the extract_content tool_call shell (id=#{extract_call_id})"

    # 4. Investigative tools are visible in the progress timeline.
    visible_tool_labels =
      obs.progress
      |> Enum.filter(fn r ->
           Map.get(r, :kind) == "tool" and not Map.get(r, :hidden, false)
         end)
      |> Enum.map(fn r -> Map.get(r, :label) || "" end)

    label_dump = Enum.map_join(visible_tool_labels, " | ", &String.downcase/1)
    assert label_dump =~ "websearch",
           "WebSearch progress row should be visible; got: #{inspect(visible_tool_labels)}"
    assert label_dump =~ "extractcontent",
           "ExtractContent progress row should be visible; got: #{inspect(visible_tool_labels)}"

    # complete_task is hidden — `SessionProgress.fetch_for_session/2`
    # filters `hidden = 0`, so the row never appears in `obs.progress`.
    # Two assertions: (1) it's NOT in the visible timeline (already
    # implied by the visible_tool_labels above, but pin it down);
    # (2) the row DOES exist in the DB with `hidden = 1` so audit
    # tooling can still reach it.
    refute label_dump =~ "completetask",
           "complete_task progress row must NOT appear in the FE-visible timeline; " <>
             "got visible labels: #{inspect(visible_tool_labels)}"

    %{rows: hidden_rows} =
      query!(Repo,
        "SELECT label FROM session_progress WHERE session_id=? AND hidden=1",
        [session_id])

    hidden_labels = Enum.map(hidden_rows, fn [l] -> to_string(l || "") end)
    assert Enum.any?(hidden_labels, fn l -> String.downcase(l) =~ "completetask" end),
           "complete_task should still be persisted with hidden=1 (audit-reachable); " <>
             "got hidden labels: #{inspect(hidden_labels)}"

    # 5. Final assistant text references the synthesis.
    final_assistant =
      obs.messages
      |> Enum.filter(fn m ->
           role = m["role"] || m[:role]
           role == "assistant" and is_binary(m["content"] || m[:content])
         end)
      |> List.last()

    final_content = (final_assistant["content"] || final_assistant[:content]) |> to_string()
    assert final_content =~ "7,300" or final_content =~ "puddled iron",
           "delivery turn should reflect the research; got: #{inspect(final_content)}"

    # 6. chain_end on final_text path (same as F07 — empty
    #    complete_task narration → fall-through delivery turn).
    chain_end_row =
      obs.progress
      |> Enum.find(fn r -> Map.get(r, :kind) == "chain_end" end)

    assert chain_end_row
    cause = Map.get(chain_end_row, :label) || Map.get(chain_end_row, "label")
    assert cause == "final_text",
           "complete_task with empty narration → final_text close; got: #{inspect(cause)}"
  end
end
