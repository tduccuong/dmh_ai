# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F04 — Confidant turn with web-search pre-step.
#
# Confidant runs TWO retrievals in parallel BEFORE the final LLM
# stream — memo retrieval (vector search against the user's
# encrypted memos) and web search (planner LLM call → SearXNG +
# page fetch). Either or both can no-op:
#
#   * memo: skipped when the user has no MMK in process state.
#   * web : skipped when the planner returns `SEARCH: NO`.
#
# The web pre-step has two LLM round-trips:
#
#   1. Planner: `WebSearchEngine.generate_search_queries/4` calls
#      `LLM.call/3` (intercepted by `T.stub_llm_call/1`) with the
#      planner prompt; returns text that the parser splits on
#      `SEARCH:` / `CATEGORY:` / `LANG:` lines.
#   2. Engine: `call_search_engine/3` runs the queries through
#      SearXNG + page fetcher (intercepted by the new
#      `T.stub_web_search/1` hook).
#
# Confidant's final LLM stream goes through `LLM.stream/4` →
# `T.stub_llm_stream/1` and persists the assistant text to
# `session.messages`.
#
# F04 covers the two planner branches:
#
#   * SEARCH:NO  — pre-step short-circuits, no `confidant_websearch`
#                  progress row; final assistant text reaches the user.
#   * SEARCH:YES — engine stub fires with the planned queries +
#                  category; `confidant_websearch` progress row
#                  appended; the engine's snippets are folded into
#                  the LLM context (observable as a substring in the
#                  user-role messages the stream stub sees).

defmodule DmhAi.Flows.F04ConfidantWebSearch do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{ConfidantCommand, SessionProgress, UserAgent, UserAgentMessages}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F04"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F04")
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
      [session_id, user_id, "confidant", "[]", "[]",
       System.os_time(:millisecond), System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM session_progress WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "planner says SEARCH:NO → confidant runs without web pre-step",
       %{user_id: user_id, session_id: session_id} do
    # Planner stub — fires on `LLM.call`. Memo retrieval is skipped
    # automatically (no MMK in this fresh test user's state), so this
    # stub catches the planner call only.
    planner_calls = :counters.new(1, [:atomics])

    T.stub_llm_call(fn _model, _msgs, _opts ->
      :counters.add(planner_calls, 1, 1)
      {:ok, "SEARCH: NO"}
    end)

    # If the planner-NO path ever leaks into call_search_engine, this
    # stub fails the test loud.
    T.stub_web_search(fn _queries, _category, _opts ->
      flunk("call_search_engine must NOT be called when planner says SEARCH:NO")
    end)

    # Confidant LLM stream — final user-facing answer.
    T.stub_llm_stream(fn _model, msgs, _reply_pid, _opts ->
      # Sanity: the user message that arrived as content carries through.
      user_dump = msgs |> Enum.map_join(" ", fn m -> to_string(m["content"] || m[:content] || "") end)
      assert user_dump =~ "why does",
             "confidant LLM should see the user's question in context; got: #{inspect(user_dump)}"
      {:ok, "Tides happen because of the Moon and the Sun's gravity."}
    end)

    drive_confidant(user_id, session_id, "why does the sea have tides?")

    assert :counters.get(planner_calls, 1) >= 1,
           "planner should have been consulted at least once; got: #{:counters.get(planner_calls, 1)}"

    # No `confidant_websearch` progress row.
    progress = SessionProgress.fetch_for_session(session_id, 0)
    refute Enum.any?(progress, fn r -> Map.get(r, :kind) == "confidant_websearch" end),
           "no confidant_websearch row should appear when planner returns SEARCH:NO; got kinds: #{inspect(Enum.map(progress, & &1.kind))}"

    # Final assistant message persisted.
    final = read_final_assistant(session_id)
    assert final =~ "Moon" or final =~ "tides",
           "confidant assistant text should reach session.messages; got: #{inspect(final)}"
  end

  test "planner says SEARCH:YES → engine runs with planned queries → snippets reach LLM context",
       %{user_id: user_id, session_id: session_id} do
    planner_calls = :counters.new(1, [:atomics])

    T.stub_llm_call(fn _model, _msgs, _opts ->
      :counters.add(planner_calls, 1, 1)
      {:ok,
       """
       SEARCH: YES
       CATEGORY: news
       LANG:en latest news on the typhoon
       """}
    end)

    engine_calls = :counters.new(1, [:atomics])

    T.stub_web_search(fn queries, category, _opts ->
      :counters.add(engine_calls, 1, 1)

      assert category == "news",
             "engine stub should receive the planner's category; got: #{inspect(category)}"

      assert is_list(queries) and length(queries) >= 1,
             "engine stub should receive at least one planned query; got: #{inspect(queries)}"

      [first | _] = queries
      assert first.text =~ "typhoon",
             "planned query should round-trip; got: #{inspect(first)}"
      assert first.lang == "en"

      # `Web.Search` produces atom-keyed maps; `format_raw_results/1`
      # in user_agent.ex reads `s.title`, `s.url`, `s.snippet`,
      # `p.url`, `p.content`. Mirror that shape exactly.
      %{
        snippets: [
          %{
            title:   "Typhoon update — coastal advisory",
            url:     "https://example.test/typhoon-update",
            snippet: "Storm landed at 04:00 local time. Heavy rain through tomorrow."
          }
        ],
        pages: [
          %{
            url:     "https://example.test/typhoon-update",
            content: "STUBBED PAGE BODY: Heavy rain expected for the next 24 hours; coastal advisory remains in effect."
          }
        ]
      }
    end)

    snippet_seen = :counters.new(1, [:atomics])

    T.stub_llm_stream(fn _model, msgs, _reply_pid, _opts ->
      msg_dump =
        msgs
        |> Enum.map_join("\n", fn m -> to_string(m["content"] || m[:content] || "") end)

      if msg_dump =~ "STUBBED PAGE BODY" or msg_dump =~ "coastal advisory" do
        :counters.add(snippet_seen, 1, 1)
      end

      {:ok, "Coastal advisory in effect — heavy rain through tomorrow."}
    end)

    drive_confidant(user_id, session_id, "what's the latest on the typhoon?")

    assert :counters.get(planner_calls, 1) >= 1
    assert :counters.get(engine_calls, 1) == 1,
           "call_search_engine should fire exactly once on a SEARCH:YES turn; got: #{:counters.get(engine_calls, 1)}"

    assert :counters.get(snippet_seen, 1) >= 1,
           "stubbed search results must be folded into the confidant LLM's user context"

    progress = SessionProgress.fetch_for_session(session_id, 0)

    websearch_row =
      Enum.find(progress, fn r -> Map.get(r, :kind) == "confidant_websearch" end)

    assert websearch_row,
           "confidant_websearch progress row should appear when planner says YES; got kinds: #{inspect(Enum.map(progress, & &1.kind))}"

    assert Map.get(websearch_row, :status) in ["done", "pending"],
           "confidant_websearch row should have a status; got: #{inspect(websearch_row)}"

    final = read_final_assistant(session_id)
    assert final =~ "rain" or final =~ "advisory",
           "confidant assistant text should reflect the search-grounded answer; got: #{inspect(final)}"
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp drive_confidant(user_id, session_id, content) do
    test_pid = self()

    {:ok, _ts} =
      UserAgentMessages.append(session_id, user_id, %{role: "user", content: content})

    cmd = %ConfidantCommand{
      type:       :chat,
      content:    content,
      session_id: session_id,
      reply_pid:  test_pid,
      images:     [],
      image_names: [],
      files:      [],
      has_video:  false
    }

    spawn_link(fn ->
      _ = UserAgent.dispatch_confidant(user_id, cmd)
    end)

    :ok = wait_until_idle(user_id, 8_000)
  end

  defp read_final_assistant(session_id) do
    %{rows: [[messages_json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    messages = Jason.decode!(messages_json || "[]")

    case messages
         |> Enum.filter(fn m -> (m["role"] || m[:role]) == "assistant" end)
         |> List.last() do
      nil  -> ""
      msg  -> (msg["content"] || msg[:content]) |> to_string()
    end
  end

  defp wait_until_idle(user_id, timeout_ms) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until_idle(user_id, deadline, nil)
  end

  defp do_wait_until_idle(user_id, deadline, idle_since) do
    grace_ms = 200

    cond do
      System.os_time(:millisecond) > deadline ->
        flunk("F04: confidant turn never reached idle within deadline")

      UserAgent.current_turn_session_id(user_id) != nil ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, nil)

      is_nil(idle_since) ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, System.os_time(:millisecond))

      System.os_time(:millisecond) - idle_since >= grace_ms ->
        :ok

      true ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, idle_since)
    end
  end
end
