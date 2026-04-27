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

      assert {:rejected, {:duplicate_tool_call_in_chain, reason}} =
               Police.check_no_duplicate_tool_call(
                 "create_task", %{"task_title" => "research X"}, prior)

      assert reason =~ "`create_task`"
      assert reason =~ "task_title"
    end

    test "rejects duplicate create_task with case / whitespace variation" do
      prior = [assistant_tool_msg("create_task", %{"task_title" => "  Research X  "})]

      assert {:rejected, {:duplicate_tool_call_in_chain, _}} =
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

      assert {:rejected, {:duplicate_tool_call_in_chain, _}} =
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

      assert {:rejected, {:duplicate_tool_call_in_chain, _}} =
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
      # Tools outside (create_task, extract_content, web_search,
      # run_script, task verbs) bypass — too niche to define dedup
      # semantics for yet.
      prior = [assistant_tool_msg("datetime", %{})]

      assert :ok =
               Police.check_no_duplicate_tool_call("datetime", %{}, prior)
    end

    test "rejects duplicate run_script with byte-identical script" do
      script = "curl -s https://api.example.com/foo | jq ."
      prior = [assistant_tool_msg("run_script", %{"script" => script})]

      assert {:rejected, {:duplicate_tool_call_in_chain, reason}} =
               Police.check_no_duplicate_tool_call(
                 "run_script", %{"script" => script}, prior)

      assert reason =~ "`run_script`"
      assert reason =~ "normalized script"
    end

    test "rejects duplicate run_script with comment-only differences" do
      # Real-world failure: model loops on the same curl, varying only
      # the leading comment. Normalisation strips comments → match.
      first  = """
      # Fetch the deal stages
      curl -s https://api.example.com/stages | jq '.result'
      """
      second = """
      # Try fetching deal stages again with the correct syntax
      curl -s https://api.example.com/stages | jq '.result'
      """
      prior = [assistant_tool_msg("run_script", %{"script" => first})]

      assert {:rejected, {:duplicate_tool_call_in_chain, _}} =
               Police.check_no_duplicate_tool_call(
                 "run_script", %{"script" => second}, prior)
    end

    test "rejects duplicate run_script with whitespace-only differences" do
      first  = "curl -s https://api.example.com/foo  |   jq ."
      second = "curl -s https://api.example.com/foo | jq ."
      prior = [assistant_tool_msg("run_script", %{"script" => first})]

      assert {:rejected, {:duplicate_tool_call_in_chain, _}} =
               Police.check_no_duplicate_tool_call(
                 "run_script", %{"script" => second}, prior)
    end

    test ":ok when run_script scripts differ in URL / args / flags" do
      first  = "curl -s https://api.example.com/stages | jq '.result'"
      second = "curl -s https://api.example.com/users | jq '.result'"
      prior = [assistant_tool_msg("run_script", %{"script" => first})]

      assert :ok =
               Police.check_no_duplicate_tool_call(
                 "run_script", %{"script" => second}, prior)
    end

    test ":ok when run_script script is empty / missing" do
      prior = [assistant_tool_msg("run_script", %{"script" => ""})]

      assert :ok =
               Police.check_no_duplicate_tool_call(
                 "run_script", %{"script" => ""}, prior)
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

      assert {:rejected, {:duplicate_tool_call_in_chain, _}} =
               Police.check_no_duplicate_tool_call(
                 "extract_content", %{"path" => "workspace/x.pdf"}, prior)
    end
  end

  # ─── Consecutive web_search Police gate ─────────────────────────────────

  describe "Police.check_no_consecutive_web_search/3" do
    defp ws_tool_msg(name) do
      %{"role" => "assistant", "tool_calls" => [
        %{"id" => uid(),
          "function" => %{"name" => name, "arguments" => %{}}}
      ]}
    end

    defp ws_tool_msg_multi(names) do
      %{"role" => "assistant", "tool_calls" =>
        Enum.map(names, fn n ->
          %{"id" => uid(), "function" => %{"name" => n, "arguments" => %{}}}
        end)}
    end

    test ":ok when prior-message list is empty (first web_search of the turn)" do
      assert :ok = Police.check_no_consecutive_web_search(
                     "web_search", %{"query" => "anything"}, [])
    end

    test ":ok when the current call isn't web_search — gate only targets web_search" do
      prior = [ws_tool_msg("web_search")]

      # run_script right after web_search is the ENCOURAGED path (dig deeper).
      assert :ok = Police.check_no_consecutive_web_search(
                     "run_script", %{"script" => "curl x"}, prior)
    end

    test "rejects web_search when the prior-round tool call was also web_search" do
      prior = [ws_tool_msg("web_search")]

      assert {:rejected, {:consecutive_web_search, reason}} =
               Police.check_no_consecutive_web_search(
                 "web_search", %{"query" => "q2"}, prior)

      # Nudge must TEACH the correct loop, not just scold.
      assert reason =~ "DIGEST"
      assert reason =~ "DIG DEEPER"
      assert reason =~ "web_fetch"
      assert reason =~ "run_script"
    end

    test "rejects INTRA-BATCH: second web_search in the same batch after a first web_search" do
      # execute_tools appends a per-call pseudo-message as it iterates, so
      # within one batch [web_search, web_search] the second call sees the
      # first in prior_acc and must be rejected.
      prior = [ws_tool_msg("web_search")]

      assert {:rejected, {:consecutive_web_search, _}} =
               Police.check_no_consecutive_web_search(
                 "web_search", %{"query" => "q2"}, prior)
    end

    test ":ok when alternating: web_search → run_script → web_search" do
      # The canonical LEGITIMATE pattern: search, dig with a different tool,
      # then refine-search based on what was found.
      prior = [
        ws_tool_msg("web_search"),
        ws_tool_msg("run_script")
      ]

      assert :ok = Police.check_no_consecutive_web_search(
                     "web_search", %{"query" => "refined"}, prior)
    end

    test ":ok when alternating: web_search → web_fetch → web_search" do
      prior = [
        ws_tool_msg("web_search"),
        ws_tool_msg("web_fetch")
      ]

      assert :ok = Police.check_no_consecutive_web_search(
                     "web_search", %{"query" => "refined"}, prior)
    end

    test "mixed-batch: the LAST call in the last batch determines the gate" do
      # Last batch was [create_task, web_search]. Current web_search is
      # rejected because the last tool-call in that batch was web_search.
      prior = [ws_tool_msg_multi(["create_task", "web_search"])]

      assert {:rejected, {:consecutive_web_search, _}} =
               Police.check_no_consecutive_web_search(
                 "web_search", %{"query" => "q"}, prior)
    end

    test "mixed-batch alternate: prior batch ended with run_script → web_search allowed" do
      # Last batch was [web_search, run_script]. Current web_search is OK
      # because the immediately-prior call was run_script.
      prior = [ws_tool_msg_multi(["web_search", "run_script"])]

      assert :ok = Police.check_no_consecutive_web_search(
                     "web_search", %{"query" => "q"}, prior)
    end

    test "ignores non-assistant messages in prior history" do
      # Tool-result messages and user messages between assistant turns
      # shouldn't confuse the walk-backwards lookup.
      prior = [
        ws_tool_msg("web_search"),
        %{"role" => "tool", "content" => "...results...", "tool_call_id" => "x"},
        %{"role" => "user", "content" => "follow up"}
      ]

      assert {:rejected, {:consecutive_web_search, _}} =
               Police.check_no_consecutive_web_search(
                 "web_search", %{"query" => "q"}, prior)
    end
  end

  # ─── run_script probe-budget Police gate ─────────────────────────────────

  describe "Police.check_run_script_probe_budget/3" do
    defp rs_msg(script) do
      %{"role" => "assistant", "tool_calls" => [
        %{"id" => uid(),
          "function" => %{"name" => "run_script", "arguments" => %{"script" => script}}}
      ]}
    end

    test ":ok when no prior run_scripts" do
      assert :ok =
               Police.check_run_script_probe_budget(
                 "run_script", %{"script" => "echo hi"}, [])
    end

    test ":ok with 1 prior run_script (under budget)" do
      prior = [rs_msg("curl https://example.com/probe1")]

      assert :ok =
               Police.check_run_script_probe_budget(
                 "run_script", %{"script" => "curl https://example.com/probe2"}, prior)
    end

    test ":ok with 4 prior run_scripts (still under budget=5)" do
      prior = [
        rs_msg("curl https://example.com/probe1"),
        rs_msg("curl https://example.com/probe2"),
        rs_msg("curl https://example.com/probe3"),
        rs_msg("curl https://example.com/probe4")
      ]

      assert :ok =
               Police.check_run_script_probe_budget(
                 "run_script", %{"script" => "curl https://example.com/probe5"}, prior)
    end

    test "rejects 6th run_script when 5 prior run_scripts exist" do
      prior =
        Enum.map(1..5, fn i ->
          rs_msg("curl https://example.com/probe#{i}")
        end)

      assert {:rejected, {:run_script_probe_budget, reason}} =
               Police.check_run_script_probe_budget(
                 "run_script", %{"script" => "curl https://example.com/probe6"}, prior)

      assert reason =~ "probed enough"
      assert reason =~ "ONLY one more chance"
      assert reason =~ "ask the user"
    end

    test ":ok when current call isn't run_script (gate scoped to run_script only)" do
      prior =
        Enum.map(1..5, fn i ->
          rs_msg("curl https://example.com/probe#{i}")
        end)

      assert :ok =
               Police.check_run_script_probe_budget(
                 "web_search", %{"query" => "anything"}, prior)
    end

    test "counts run_scripts even when interleaved with other tools" do
      # Once on a probing trajectory, mixing in other tools doesn't reset.
      prior = [
        rs_msg("curl ... probe1"),
        %{"role" => "assistant", "tool_calls" => [
          %{"id" => uid(),
            "function" => %{"name" => "web_fetch",
                            "arguments" => %{"url" => "https://docs.example.com/"}}}
        ]},
        rs_msg("curl ... probe2"),
        %{"role" => "assistant", "tool_calls" => [
          %{"id" => uid(),
            "function" => %{"name" => "read_file",
                            "arguments" => %{"path" => "workspace/notes.md"}}}
        ]},
        rs_msg("curl ... probe3"),
        rs_msg("curl ... probe4"),
        rs_msg("curl ... probe5")
      ]

      assert {:rejected, {:run_script_probe_budget, _}} =
               Police.check_run_script_probe_budget(
                 "run_script", %{"script" => "curl ... probe6"}, prior)
    end

    test "counts intra-batch run_scripts (multiple tool_calls in one assistant msg)" do
      # Model emits 5 run_scripts in a single batch — the 6th in a
      # subsequent batch should still trip the gate.
      prior = [%{"role" => "assistant", "tool_calls" =>
        Enum.map(1..5, fn i ->
          %{"id" => uid(),
            "function" => %{"name" => "run_script", "arguments" => %{"script" => "s#{i}"}}}
        end)
      }]

      assert {:rejected, {:run_script_probe_budget, _}} =
               Police.check_run_script_probe_budget(
                 "run_script", %{"script" => "extra"}, prior)
    end
  end

  # ─── Single-periodic-per-session Police gate ─────────────────────────────

  describe "Police.check_no_duplicate_periodic_task_in_session/3" do
    alias Dmhai.Agent.Tasks
    alias Dmhai.Repo
    import Ecto.Adapters.SQL, only: [query!: 3]

    defp seed_plain_session(sid, user_id) do
      now = System.os_time(:millisecond)
      query!(Repo,
        "INSERT OR IGNORE INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
        [sid, user_id, "assistant", "[]", now, now])
    end

    test ":ok when task_type is not periodic (one_off bypasses the gate)" do
      sid = uid(); uid_ = uid(); seed_plain_session(sid, uid_)
      # Seed an existing periodic — but current call is one_off, so the
      # gate MUST bypass. One_off tasks are never capped.
      _tid = Tasks.insert(user_id: uid_, session_id: sid,
                          task_title: "existing", task_spec: "x",
                          task_type: "periodic", intvl_sec: 30)

      assert :ok = Police.check_no_duplicate_periodic_task_in_session(
                     "create_task",
                     %{"task_type" => "one_off", "task_title" => "something new"},
                     %{session_id: sid})
    end

    test ":ok when no active periodic exists (first periodic in the session)" do
      sid = uid(); uid_ = uid(); seed_plain_session(sid, uid_)

      assert :ok = Police.check_no_duplicate_periodic_task_in_session(
                     "create_task",
                     %{"task_type" => "periodic", "task_title" => "joke every 30s"},
                     %{session_id: sid})
    end

    test ":ok for non-create_task calls (gate only guards creation)" do
      sid = uid(); uid_ = uid(); seed_plain_session(sid, uid_)
      _tid = Tasks.insert(user_id: uid_, session_id: sid,
                          task_title: "jokes", task_spec: "x",
                          task_type: "periodic", intvl_sec: 30)

      # pickup_task doesn't create tasks, so the duplicate-periodic gate
      # should not fire on it. Pre-verb-API this test used update_task.
      assert :ok = Police.check_no_duplicate_periodic_task_in_session(
                     "pickup_task",
                     %{"task_id" => "something"},
                     %{session_id: sid})
    end

    test ":ok when ctx lacks session_id (non-session callers bypass)" do
      sid = uid(); uid_ = uid(); seed_plain_session(sid, uid_)
      _tid = Tasks.insert(user_id: uid_, session_id: sid,
                          task_title: "jokes", task_spec: "x",
                          task_type: "periodic", intvl_sec: 30)

      assert :ok = Police.check_no_duplicate_periodic_task_in_session(
                     "create_task",
                     %{"task_type" => "periodic"},
                     %{})
    end

    test "rejects second periodic when session already has a pending periodic" do
      sid = uid(); uid_ = uid(); seed_plain_session(sid, uid_)
      _tid = Tasks.insert(user_id: uid_, session_id: sid,
                          task_title: "joke every 30s", task_spec: "x",
                          task_type: "periodic", intvl_sec: 30)

      assert {:rejected, {:duplicate_periodic_task_in_session, reason}} =
               Police.check_no_duplicate_periodic_task_in_session(
                 "create_task",
                 %{"task_type" => "periodic", "task_title" => "stock quote every 60s"},
                 %{session_id: sid})

      # Nudge must be educational AND user-facing — the model needs to
      # relay the specific phrasing to the user.
      assert reason =~ "already has an active periodic"
      assert reason =~ "DMH-AI supports at most ONE periodic"
      assert reason =~ "DMH-AI only supports 1 periodic task per chat session"
      # Must mention the (N) number format so the user sees a stable ref.
      # Phase 3: task_id is BE-internal and no longer surfaced in nudges.
      assert reason =~ ~r/task \(\d+\)|task \(\?\)/
      # Must NOT leak the cryptic task_id — only (N) is user-/model-facing.
      refute reason =~ "`XgxD8UnSDBbp`" # sanity: no backticked-crypto-id patterns
    end

    test "rejects even when existing periodic is ongoing (mid-turn)" do
      sid = uid(); uid_ = uid(); seed_plain_session(sid, uid_)
      tid = Tasks.insert(user_id: uid_, session_id: sid,
                         task_title: "active", task_spec: "x",
                         task_type: "periodic", intvl_sec: 30)
      Tasks.mark_ongoing(tid)

      assert {:rejected, {:duplicate_periodic_task_in_session, _}} =
               Police.check_no_duplicate_periodic_task_in_session(
                 "create_task",
                 %{"task_type" => "periodic", "task_title" => "another"},
                 %{session_id: sid})
    end

    test ":ok after existing periodic is cancelled (slot freed)" do
      sid = uid(); uid_ = uid(); seed_plain_session(sid, uid_)
      tid = Tasks.insert(user_id: uid_, session_id: sid,
                         task_title: "going away", task_spec: "x",
                         task_type: "periodic", intvl_sec: 30)
      Tasks.mark_cancelled(tid)

      assert :ok = Police.check_no_duplicate_periodic_task_in_session(
                     "create_task",
                     %{"task_type" => "periodic", "task_title" => "replacement"},
                     %{session_id: sid})
    end
  end

  # ─── Silent-turn scope Police gate (rule #9) ─────────────────────────────

  describe "Police.check_silent_turn_scope/3" do
    test ":ok when ctx has no :silent_turn_task_id (user-initiated turn bypasses)" do
      assert :ok = Police.check_silent_turn_scope(
                     "create_task",
                     %{"task_type" => "periodic", "task_title" => "x"},
                     %{session_id: "s1"})
    end

    # Phase 3: silent-turn scope keys on `anchor_task_num` (integer).
    # ctx carries both `:silent_turn_task_id` (retained — still used as
    # presence marker) AND `:anchor_task_num` (the integer the scope
    # gate compares against args["task_num"]).
    defp silent_ctx do
      %{session_id: "s1", silent_turn_task_id: "tsk_pickup", anchor_task_num: 5}
    end

    test "silent turn: rejects create_task" do
      ctx = silent_ctx()

      assert {:rejected, {:silent_turn_create_task, reason}} =
               Police.check_silent_turn_scope(
                 "create_task",
                 %{"task_type" => "periodic", "task_title" => "hijack attempt"},
                 ctx)

      # Nudge names the pickup task (by (N)) and points at complete_task.
      assert reason =~ "5"
      assert reason =~ "SILENT" or reason =~ "scope" or reason =~ "pickup"
      assert reason =~ "complete_task"
    end

    test "silent turn: rejects create_task regardless of task_type (one_off or periodic)" do
      ctx = silent_ctx()

      assert {:rejected, {:silent_turn_create_task, _}} =
               Police.check_silent_turn_scope(
                 "create_task",
                 %{"task_type" => "one_off", "task_title" => "one-off hijack"},
                 ctx)
    end

    test "silent turn: allows complete_task on the SAME task_num (the pickup target)" do
      ctx = silent_ctx()

      assert :ok = Police.check_silent_turn_scope(
                     "complete_task",
                     %{"task_num" => 5, "task_result" => "delivered"},
                     ctx)
    end

    test "silent turn: allows cancel_task on the SAME task_num" do
      # Edge case — the model legitimately wants to cancel the pickup
      # task itself (e.g. user requested stop in a prior turn and the
      # scheduler fired before the cancel propagated). Scope rule only
      # forbids OTHER task_nums; this path stays open.
      ctx = silent_ctx()

      assert :ok = Police.check_silent_turn_scope(
                     "cancel_task",
                     %{"task_num" => 5, "reason" => "user requested stop"},
                     ctx)
    end

    test "silent turn: allows pickup_task on the SAME task_num (idempotent re-pickup)" do
      ctx = silent_ctx()

      assert :ok = Police.check_silent_turn_scope(
                     "pickup_task",
                     %{"task_num" => 5},
                     ctx)
    end

    test "silent turn: rejects complete_task on a DIFFERENT task_num" do
      ctx = silent_ctx()

      assert {:rejected, {:silent_turn_other_task_verb, reason}} =
               Police.check_silent_turn_scope(
                 "complete_task",
                 %{"task_num" => 7, "task_result" => "freeing slot"},
                 ctx)

      # Nudge names both (N)s and points back to the pickup target.
      assert reason =~ "5"
      assert reason =~ "7"
    end

    test "silent turn: rejects cancel_task on a DIFFERENT task_num" do
      ctx = silent_ctx()

      assert {:rejected, {:silent_turn_other_task_verb, _}} =
               Police.check_silent_turn_scope(
                 "cancel_task",
                 %{"task_num" => 7},
                 ctx)
    end

    test "silent turn: rejects pickup_task on a DIFFERENT task_num" do
      ctx = silent_ctx()

      assert {:rejected, {:silent_turn_other_task_verb, _}} =
               Police.check_silent_turn_scope(
                 "pickup_task",
                 %{"task_num" => 7},
                 ctx)
    end

    test "silent turn: rejects pause_task on a DIFFERENT task_num" do
      ctx = silent_ctx()

      assert {:rejected, {:silent_turn_other_task_verb, _}} =
               Police.check_silent_turn_scope(
                 "pause_task",
                 %{"task_num" => 7},
                 ctx)
    end

    test "silent turn: allows execution tools (run_script, web_fetch, etc.)" do
      ctx = silent_ctx()

      # These are exactly how the model produces the pickup's output —
      # never blocked by the scope gate.
      for tool <- ["run_script", "web_fetch", "web_search", "extract_content",
                   "read_file", "write_file", "calculator",
                   "save_creds", "lookup_creds", "delete_creds", "spawn_task",
                   "fetch_task"] do
        assert :ok = Police.check_silent_turn_scope(tool, %{"any" => "args"}, ctx),
               "execution tool `#{tool}` must be allowed in silent turns"
      end
    end

    test "silent turn: complete_task with missing/non-integer task_num is :ok (schema check handles it)" do
      # If the model emits a verb without task_num or with a non-integer
      # value, Police.check_tool_call_schema catches it with a
      # schema-driven nudge. The scope gate should not double-reject —
      # it only fires when task_num is a proper integer AND different
      # from the pickup's anchor_task_num.
      ctx = silent_ctx()

      assert :ok = Police.check_silent_turn_scope(
                     "complete_task", %{"task_result" => "x"}, ctx)
      assert :ok = Police.check_silent_turn_scope(
                     "complete_task", %{"task_num" => ""}, ctx)
    end
  end
end
