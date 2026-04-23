# Integration tests: session_data contract + duplicate-tool-call Police gate.
# Run with: MIX_ENV=test mix test test/itgr_session_context_contract.exs
#
# Covers the wiring gap where `UserAgent.load_session/2` used to omit
# `"id"` from its return map — which silently disabled BOTH the
# tool_history interleaving AND the `## Recently-extracted files` block
# in ContextEngine.build_assistant_messages/2. The prior test file
# (itgr_context_tool_integration.exs) manually injected `"id"` into
# session_data and so could not catch the production wiring bug.
#
# The tests here are organised around three concerns (contract, logic,
# shape) plus the new duplicate-tool-call Police gate.

defmodule Itgr.SessionContextContract do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{ContextEngine, Police, UserAgent}
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_session(sid, user_id, opts) do
    now = System.os_time(:millisecond)
    mode         = Keyword.get(opts, :mode, "assistant")
    messages     = Keyword.get(opts, :messages, [])
    tool_history = Keyword.get(opts, :tool_history, nil)

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
      [sid, user_id, mode, Jason.encode!(messages), tool_history, now, now])
  end

  defp find_msg(msgs, role, pred) do
    Enum.find(msgs, fn m -> m.role == role and pred.(m.content) end)
  end

  # ─── Contract: load_session/2 populates required fields ──────────────────

  test "load_session/2 returns session_data carrying \"id\" so downstream code doesn't silently skip features" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_, messages: [T.user_msg("hi")])

    {:ok, _model, sd} = UserAgent.load_session(sid, uid_)

    assert sd["id"] == sid,
           "load_session/2 must populate \"id\" — ContextEngine uses it to load tool_history"
    assert sd["mode"] == "assistant"
    assert is_list(sd["messages"])
    assert is_map(sd["context"])
  end

  test "load_session/2 returns error when session not found (doesn't silently return an id-less map)" do
    {:error, reason} = UserAgent.load_session("does-not-exist-#{uid()}", uid())
    assert is_binary(reason)
  end

  # ─── Contract: ContextEngine raises loudly when id is missing ────────────

  test "build_assistant_messages/2 raises ArgumentError when session_data lacks \"id\"" do
    # Defensive guard — future callers constructing session_data maps
    # without "id" should hit a clear error instead of quietly losing the
    # Recently-extracted files block AND the tool_history injection.
    bogus = %{"messages" => [T.user_msg("hi")], "context" => nil}

    assert_raise ArgumentError, ~r/must include a non-empty "id"/, fn ->
      ContextEngine.build_assistant_messages(bogus)
    end
  end

  test "build_assistant_messages/2 raises ArgumentError when \"id\" is nil" do
    bogus = %{"id" => nil, "messages" => [T.user_msg("hi")], "context" => nil}

    assert_raise ArgumentError, ~r/must include a non-empty "id"/, fn ->
      ContextEngine.build_assistant_messages(bogus)
    end
  end

  test "build_assistant_messages/2 raises ArgumentError when \"id\" is empty string" do
    bogus = %{"id" => "", "messages" => [T.user_msg("hi")], "context" => nil}

    assert_raise ArgumentError, ~r/must include a non-empty "id"/, fn ->
      ContextEngine.build_assistant_messages(bogus)
    end
  end

  # ─── End-to-end: real load path → build_assistant_messages ───────────────
  #
  # The REAL production failure mode: with the broken load_session, the
  # test below would produce an assembled message list with NO
  # Recently-extracted block, even though tool_history has an entry.
  # The fix makes this test pass.

  test "SQL-seeded session flowing through load_session + build_assistant_messages injects the Recently-extracted block" do
    sid = uid(); uid_ = uid()
    path = "workspace/contract-test-#{uid()}.pdf"

    # The assistant_ts in tool_history must match an assistant message's ts
    # in sessions.messages for ToolHistory.inject/2 to splice the
    # tool_call/tool_result messages back in.
    assistant_ts = System.os_time(:millisecond) - 60_000

    # Turn 1 (user + assistant) is history; turn 2's user message is the
    # "current" message the Assistant needs to answer. ToolHistory.inject
    # splices the retained tool_call/tool_result pair BEFORE the turn-1
    # assistant message, matched by ts. A test without a follow-up user
    # message would put the assistant in the "last_msgs" slice instead of
    # history — where inject doesn't reach.
    messages = [
      %{"role" => "user",      "content" => "summarise the pdf I attached"},
      %{"role" => "assistant", "content" => "Here is the summary…", "ts" => assistant_ts},
      %{"role" => "user",      "content" => "what about section 3?"}
    ]

    tool_history = [
      %{
        "assistant_ts" => assistant_ts,
        "messages" => [
          %{"role" => "assistant", "content" => "", "tool_calls" => [
            %{"id" => "c1",
              "function" => %{
                "name" => "extract_content",
                "arguments" => %{"path" => path}
              }}
          ]},
          %{"role" => "tool",
            "content" => "EXTRACTED_BODY_MARKER-#{uid()}",
            "tool_call_id" => "c1"}
        ]
      }
    ]

    seed_session(sid, uid_,
      messages: messages,
      tool_history: Jason.encode!(tool_history))

    # Exercise the REAL loader — no manual session_data construction.
    {:ok, _model, sd} = UserAgent.load_session(sid, uid_)
    assert sd["id"] == sid, "contract guard — loader must populate id"

    assembled = ContextEngine.build_assistant_messages(sd)

    # --- LOGIC: the Recently-extracted files block must be injected. ---
    block = find_msg(assembled, "user",
                     &String.starts_with?(&1, "## Recently-extracted files"))
    assert block != nil,
           "Recently-extracted block MUST appear when the session was loaded " <>
             "through the real load_session/2 path (regression: used to silently disappear)"
    assert String.contains?(block.content, path),
           "block must name the extracted file path"

    # --- SHAPE: the tool_call / tool_result messages must be interleaved
    # right before the matching assistant message in history.
    # Walk the assembled list, find the assistant message with the
    # matching ts, assert the two messages IMMEDIATELY before it are
    # the re-injected tool_call + tool_result.
    idx =
      Enum.find_index(assembled, fn m ->
        role = m[:role] || m["role"]
        ts   = m[:ts]   || m["ts"]
        role == "assistant" and ts == assistant_ts
      end)

    assert is_integer(idx) and idx >= 2,
           "expected injected tool messages before the assistant(ts=#{assistant_ts}); " <>
             "idx=#{inspect(idx)} assembled=#{inspect(Enum.map(assembled, &Map.take(&1, [:role, :ts, :tool_call_id])))}"

    tool_result = Enum.at(assembled, idx - 1)
    tool_call   = Enum.at(assembled, idx - 2)

    assert (tool_result[:role] || tool_result["role"]) == "tool",
           "expected role=tool right before final assistant, got: #{inspect(tool_result)}"
    assert (tool_call[:role] || tool_call["role"]) == "assistant",
           "expected role=assistant with tool_calls two before final assistant, got: #{inspect(tool_call)}"
    assert (tool_call[:tool_calls] || tool_call["tool_calls"]) != nil,
           "interleaved assistant message must carry tool_calls"
  end

  test "SQL-seeded session with NO tool_history assembles without the Recently-extracted block (neg. control)" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_, messages: [T.user_msg("hi")])

    {:ok, _model, sd} = UserAgent.load_session(sid, uid_)
    assembled = ContextEngine.build_assistant_messages(sd)

    refute find_msg(assembled, "user",
                    &String.starts_with?(&1, "## Recently-extracted files")),
           "block must be absent when there's no tool_history — otherwise we'd be lying to the model"
  end

  # ─── Duplicate-tool-call Police gate ────────────────────────────────────

  describe "Police.check_no_duplicate_tool_call/3" do
    defp assistant_tool_msg(name, args) do
      %{"role" => "assistant", "tool_calls" => [
        %{"id" => uid(),
          "function" => %{"name" => name, "arguments" => args}}
      ]}
    end

    test ":ok when the prior-message list is empty" do
      assert :ok = Police.check_no_duplicate_tool_call(
                     "create_task", %{"task_title" => "research X"}, [])
    end

    test "rejects duplicate create_task with identical title" do
      prior = [assistant_tool_msg("create_task", %{"task_title" => "research X"})]

      assert {:rejected, {:duplicate_tool_call_in_turn, reason}} =
               Police.check_no_duplicate_tool_call(
                 "create_task", %{"task_title" => "research X"}, prior)

      assert reason =~ "`create_task`"
      assert reason =~ "task_title"
    end

    test "rejects duplicate create_task with case / whitespace variation" do
      prior = [assistant_tool_msg("create_task", %{"task_title" => "  Research X  "})]

      assert {:rejected, {:duplicate_tool_call_in_turn, _}} =
               Police.check_no_duplicate_tool_call(
                 "create_task", %{"task_title" => "research x"}, prior)
    end

    test ":ok when create_task titles differ" do
      prior = [assistant_tool_msg("create_task", %{"task_title" => "topic A"})]

      assert :ok =
               Police.check_no_duplicate_tool_call(
                 "create_task", %{"task_title" => "topic B"}, prior)
    end

    test "rejects duplicate extract_content with identical path" do
      path = "workspace/doc.pdf"
      prior = [assistant_tool_msg("extract_content", %{"path" => path})]

      assert {:rejected, {:duplicate_tool_call_in_turn, _}} =
               Police.check_no_duplicate_tool_call(
                 "extract_content", %{"path" => path}, prior)
    end

    test "extract_content path comparison is case-SENSITIVE (Linux FS)" do
      prior = [assistant_tool_msg("extract_content", %{"path" => "workspace/Foo.pdf"})]

      # Different case → different file on Linux, so must be allowed.
      assert :ok =
               Police.check_no_duplicate_tool_call(
                 "extract_content", %{"path" => "workspace/foo.pdf"}, prior)
    end

    test "rejects duplicate web_search with identical query (case-insensitive)" do
      prior = [assistant_tool_msg("web_search", %{"query" => "Elixir GenServer timing"})]

      assert {:rejected, {:duplicate_tool_call_in_turn, _}} =
               Police.check_no_duplicate_tool_call(
                 "web_search", %{"query" => "elixir genserver timing"}, prior)
    end

    test ":ok when tools differ even if significant key happens to match" do
      # Separate tools never dedupe against each other — only same-name dups
      # qualify. Models sometimes reasonably call different tools with the
      # same argument (e.g. list_dir + extract_content on same path).
      prior = [assistant_tool_msg("extract_content", %{"path" => "workspace/a.pdf"})]

      assert :ok =
               Police.check_no_duplicate_tool_call(
                 "read_file", %{"path" => "workspace/a.pdf"}, prior)
    end

    test ":ok for unrecognised tools (no significance key defined)" do
      # Tools outside (create_task, extract_content, web_search) bypass —
      # too niche to define dedup semantics for yet.
      prior = [assistant_tool_msg("datetime", %{})]

      assert :ok =
               Police.check_no_duplicate_tool_call("datetime", %{}, prior)
    end

    test ":ok when significance key arg is missing / empty" do
      prior = [assistant_tool_msg("create_task", %{"task_title" => ""})]

      assert :ok =
               Police.check_no_duplicate_tool_call(
                 "create_task", %{"task_title" => ""}, prior)
    end

    test "handles stringified JSON arguments in prior messages" do
      # LLM normalise_tool_calls sometimes hands us stringified arguments.
      # The Police check must still find the match.
      prior = [%{"role" => "assistant", "tool_calls" => [
        %{"id" => uid(),
          "function" => %{
            "name" => "extract_content",
            "arguments" => ~s({"path":"workspace/x.pdf"})
          }}
      ]}]

      assert {:rejected, {:duplicate_tool_call_in_turn, _}} =
               Police.check_no_duplicate_tool_call(
                 "extract_content", %{"path" => "workspace/x.pdf"}, prior)
    end
  end
end
