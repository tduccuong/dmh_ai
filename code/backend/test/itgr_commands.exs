# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.Commands do
  use ExUnit.Case, async: false

  alias Dmhai.Commands
  alias Dmhai.Commands.Parser
  alias Dmhai.VectorDB.Memory, as: MemoryBackend
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    Application.put_env(:dmhai, :__embedder_stub__, fn texts ->
      vecs = Enum.map(texts, fn _ ->
        # Constant 1024-dim vector — content doesn't matter for these tests.
        for _ <- 1..1024, do: :rand.uniform()
      end)
      {:ok, vecs}
    end)
    Application.put_env(:dmhai, :__tagger_stub__, fn _ -> ["test"] end)
    Application.put_env(:dmhai, :vector_db_backend, MemoryBackend)
    MemoryBackend.reset()

    # Default LLM stub for the suite — branches on the system prompt
    # so the wiki/memo paths exercising Oracle don't hit the network.
    # Individual tests override `__llm_call_stub__` for stricter
    # assertions (e.g. forcing QUERY classification).
    Application.put_env(:dmhai, :__llm_call_stub__, fn _model, msgs, _opts ->
      sys =
        case Enum.find(msgs, fn m -> Map.get(m, :role) == "system" end) do
          %{content: c} -> c
          _             -> ""
        end

      cond do
        String.contains?(sys, "translate or rephrase") ->
          # localize call — echo the message-to-express verbatim. The
          # stub doesn't actually translate; it just lets the call
          # complete so the runtime path proceeds.
          user =
            case Enum.find(msgs, fn m -> Map.get(m, :role) == "user" end) do
              %{content: c} -> c
              _             -> ""
            end

          msg =
            case Regex.run(~r/Message to express:\s*(.*)/s, user) do
              [_, body] -> String.trim(body)
              _         -> ""
            end

          {:ok, msg}

        String.contains?(sys, "classify a one-line user input") ->
          # classify call — default to SAVE with a canned ack. Tests
          # that want QUERY override this stub.
          {:ok, "SAVE\nSaved."}

        String.contains?(sys, "saved memos") ->
          {:ok, "stubbed digest answer"}

        true ->
          {:ok, ""}
      end
    end)

    sid = "cmd-#{T.uid()}"
    uid = "user-#{T.uid()}"
    now = System.os_time(:millisecond)

    query!(Repo, """
    INSERT INTO sessions (id, name, model, messages, user_id, mode, created_at, updated_at)
    VALUES (?, 'Test', '', '[]', ?, 'assistant', ?, ?)
    """, [sid, uid, now, now])

    on_exit(fn ->
      query!(Repo, "DELETE FROM sessions WHERE id=?", [sid])
      Application.delete_env(:dmhai, :__embedder_stub__)
      Application.delete_env(:dmhai, :__tagger_stub__)
      Application.delete_env(:dmhai, :__llm_call_stub__)
      Application.delete_env(:dmhai, :vector_db_backend)
      MemoryBackend.reset()
    end)

    {:ok, sid: sid, uid: uid}
  end

  describe "Parser" do
    test "/wiki at start with arg" do
      assert {:wiki, "https://example.com"} = Parser.parse("/wiki https://example.com")
      assert {:wiki, "some text here"} = Parser.parse("/wiki some text here")
    end

    test "/memo at start with arg" do
      assert {:memo, "my X is Y"} = Parser.parse("/memo my X is Y")
      assert {:memo, "what is my X?"} = Parser.parse("/memo what is my X?")
    end

    test "/wiki or /memo with no arg" do
      assert {:wiki, ""} = Parser.parse("/wiki")
      assert {:memo, ""}  = Parser.parse("/memo")
    end

    test "non-command messages" do
      assert :not_a_command = Parser.parse("hello world")
      assert :not_a_command = Parser.parse("/foo bar")
      assert :not_a_command = Parser.parse("")
    end

    test "command must be at the very start (after leading whitespace) — mid-message slashes are NOT commands" do
      # Body with the slash mid-text → regular user message.
      assert :not_a_command = Parser.parse("the user said /wiki yesterday")
      assert :not_a_command = Parser.parse("blah /memo bar")
      assert :not_a_command = Parser.parse("ok /wiki then")

      # Single non-whitespace char before the slash is enough to break the match.
      assert :not_a_command = Parser.parse(".  /memo x")
      assert :not_a_command = Parser.parse(">/wiki x")
    end

    test "leading whitespace of any kind is tolerated" do
      assert {:wiki, "x"} = Parser.parse("  /wiki x")
      assert {:wiki, "x"} = Parser.parse("\t/wiki x")
      assert {:memo, "y"} = Parser.parse(" \t \t /memo y")
      # A newline before the slash is just whitespace too — `String.trim_leading/1`
      # strips Unicode whitespace including \n, so this counts as command-at-start.
      assert {:memo, "y"} = Parser.parse("\n/memo y")
    end
  end

  describe "Commands.dispatch — /wiki inline text" do
    test "indexes inline text + persists kind=command + command_ack rows", %{sid: sid, uid: uid} do
      content = "/wiki The Bitrix24 webhook URL pattern is /rest/<user_id>/<token>/."

      assert {:handled, _ack_ts} = Commands.dispatch(content, sid, uid)

      # Both the original /wiki message and the ack persisted with `kind`.
      [[messages_json]] = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [sid]).rows
      msgs = Jason.decode!(messages_json)

      assert length(msgs) == 2
      [user_msg, ack_msg] = msgs
      assert user_msg["kind"] == "command"
      assert user_msg["role"] == "user"
      assert user_msg["content"] == content

      assert ack_msg["kind"] == "command_ack"
      assert ack_msg["role"] == "assistant"
      assert ack_msg["content"] =~ "indexed"
      assert ack_msg["content"] =~ "Wiki"
    end

    test "non-command messages return :not_a_command", %{sid: sid, uid: uid} do
      assert :not_a_command = Commands.dispatch("hello", sid, uid)
      # No messages persisted — caller handles the regular path.
      [[messages_json]] = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [sid]).rows
      assert Jason.decode!(messages_json) == []
    end

    test "/memo (save path) — async; kind tags filter from LLM context, ack uses Oracle's localized line",
         %{sid: sid, uid: uid} do
      # Classify replies with SAVE + a localized ack on line 2.
      # The dispatch returns immediately after persisting the user
      # message; the ack lands when the background Task completes.
      Application.put_env(:dmhai, :__llm_call_stub__, fn _model, _msgs, _opts ->
        {:ok, "SAVE\nĐã lưu vào bộ nhớ."}
      end)

      assert {:handled, user_ts} = Commands.dispatch("/memo ngân hàng của tôi là Vietcombank", sid, uid)

      # User message persisted synchronously (so user_ts can return);
      # ack lands asynchronously — poll until the count hits 2.
      msgs = wait_for_message_count(sid, 2)
      [user_msg, ack_msg] = msgs

      assert user_msg["kind"] == "command"
      assert user_msg["ts"]   == user_ts
      assert ack_msg["kind"]  == "command_ack"
      assert ack_msg["content"] == "Đã lưu vào bộ nhớ."
    end

    test "/memo (query path) — async; user msg has kind stripped, answer persisted plainly",
         %{sid: sid, uid: uid} do
      # Branching stub: classify call → return SAVE for the seed,
      # QUERY for the lookup. Digest → composed answer. All other
      # calls fall back to "" so a misroute fails loudly.
      Application.put_env(:dmhai, :__llm_call_stub__, fn _model, msgs, _opts ->
        sys =
          case Enum.find(msgs, fn m -> Map.get(m, :role) == "system" end) do
            %{content: c} -> c
            _             -> ""
          end

        user_msg =
          case Enum.find(msgs, fn m -> Map.get(m, :role) == "user" end) do
            %{content: c} -> c
            _             -> ""
          end

        cond do
          String.contains?(sys, "classify a one-line user input") ->
            # Distinguish save seed from query: presence of "?" or
            # interrogative cue → QUERY; otherwise SAVE.
            if String.contains?(user_msg, "?") or String.starts_with?(String.downcase(user_msg), "what") do
              {:ok, "QUERY"}
            else
              {:ok, "SAVE\nSaved."}
            end

          String.contains?(sys, "saved memos") ->
            {:ok, "Your X is 42."}

          true ->
            {:ok, ""}
        end
      end)

      # Seed: classify → SAVE → ingest → ack. Wait for the pair.
      assert {:handled, _seed_user_ts} = Commands.dispatch("/memo my X is 42", sid, uid)
      _ = wait_for_message_count(sid, 2)

      # Query: classify → QUERY → fetch → digest → answer. Wait
      # until both new messages have landed (4 total).
      assert {:handled, query_user_ts} = Commands.dispatch("/memo what is my X?", sid, uid)
      msgs = wait_for_message_count(sid, 4)

      # Save path: 2 kind-tagged messages.
      [save_user, save_ack | rest] = msgs
      assert save_user["kind"] == "command"
      assert save_ack["kind"]  == "command_ack"

      # Query path: 2 plain messages, NO kind tag — they belong in
      # the next turn's LLM context. The user-message kind was
      # stripped in `do_async/4` after classify returned QUERY.
      [query_user, query_answer] = rest
      refute Map.has_key?(query_user, "kind")
      refute Map.has_key?(query_answer, "kind")
      assert query_user["ts"]       == query_user_ts
      assert query_user["role"]     == "user"
      assert query_answer["role"]   == "assistant"
      assert query_answer["content"] =~ "42"
    end

    test "empty /wiki arg returns usage hint", %{sid: sid, uid: uid} do
      assert {:handled, _} = Commands.dispatch("/wiki", sid, uid)

      [[messages_json]] = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [sid]).rows
      [_user_msg, ack_msg] = Jason.decode!(messages_json)
      assert ack_msg["content"] =~ "Usage"
    end
  end

  describe "Pipeline heuristics" do
    test "URL.url?/1 recognises http(s) only" do
      alias Dmhai.Commands.Pipelines.URL, as: U
      assert U.url?("https://example.com")
      assert U.url?("http://example.com/path?q=1")
      refute U.url?("/abs/path")
      refute U.url?("ftp://example.com")
      refute U.url?("inline text")
      refute U.url?(nil)
    end

    test "File.file?/1 requires absolute path that exists" do
      alias Dmhai.Commands.Pipelines.File, as: FP
      tmp = Path.join(System.tmp_dir!(), "kb-pipe-#{T.uid()}.md")
      Elixir.File.write!(tmp, "hello world")
      on_exit(fn -> Elixir.File.rm(tmp) end)

      assert FP.file?(tmp)
      refute FP.file?("relative/path")
      refute FP.file?("/nonexistent/#{T.uid()}.md")
    end

    test "Folder.folder?/1 requires absolute path that is a directory" do
      alias Dmhai.Commands.Pipelines.Folder, as: F
      tmp = Path.join(System.tmp_dir!(), "kb-folder-#{T.uid()}")
      Elixir.File.mkdir_p!(tmp)
      on_exit(fn -> Elixir.File.rm_rf(tmp) end)

      assert F.folder?(tmp)
      refute F.folder?("/nonexistent/#{T.uid()}")
      refute F.folder?(System.tmp_dir!() <> "/relative")
    end
  end

  describe "Pipelines.Folder walk" do
    test "skiplist + extension whitelist filter the right files" do
      alias Dmhai.Commands.Pipelines.Folder

      root = Path.join(System.tmp_dir!(), "kb-folderwalk-#{T.uid()}")
      Elixir.File.mkdir_p!(Path.join(root, ".git"))
      Elixir.File.mkdir_p!(Path.join(root, "node_modules"))
      Elixir.File.mkdir_p!(Path.join(root, "src"))
      Elixir.File.mkdir_p!(Path.join(root, ".hidden"))

      Elixir.File.write!(Path.join(root, "README.md"),       "readme body content")
      Elixir.File.write!(Path.join([root, "src", "main.py"]), "print('hello')")
      Elixir.File.write!(Path.join([root, "src", "data.bin"]), "skipped binary")
      Elixir.File.write!(Path.join([root, ".git", "config"]),  "git config skipped")
      Elixir.File.write!(Path.join([root, "node_modules", "lodash.js"]), "skipped js in node_modules")
      Elixir.File.write!(Path.join([root, ".hidden", "secret.md"]),     "hidden dir skipped")

      on_exit(fn -> Elixir.File.rm_rf(root) end)

      eligible = Folder.list_eligible_files(root)
      basenames = Enum.map(eligible, &Path.basename/1) |> Enum.sort()

      # Eligible: README.md (text in root), main.py (code in src).
      assert "README.md" in basenames
      assert "main.py" in basenames

      # Skipped: .git, node_modules, .hidden subdirs entirely; data.bin (no whitelisted ext).
      refute "config" in basenames        # under .git
      refute "lodash.js" in basenames     # under node_modules
      refute "secret.md" in basenames     # under .hidden
      refute "data.bin" in basenames      # extension not whitelisted
    end
  end

  describe "Pipelines.File.run" do
    test "indexes a real text file", %{sid: sid, uid: uid} do
      alias Dmhai.Commands.Pipelines.File, as: FP
      tmp = Path.join(System.tmp_dir!(), "kb-pipe-#{T.uid()}.md")
      body = "# Heading\n\nThis is a sample document used for the file pipeline test.\n"
      Elixir.File.write!(tmp, body)
      on_exit(fn -> Elixir.File.rm(tmp) end)

      assert {:ok, msg} = FP.run(tmp, sid, uid)
      assert msg =~ "indexed"
      assert msg =~ "Wiki"
      assert msg =~ Path.basename(tmp)
    end
  end

  describe "ContextEngine — kind filter" do
    test "command and command_ack messages are excluded from LLM context", %{sid: sid, uid: uid} do
      # Persist 4 messages: a real exchange + a /wiki command + its ack.
      now = System.os_time(:millisecond)

      session_data = %{
        "id" => sid,
        "user_id" => uid,
        "messages" => [
          %{"role" => "user",      "content" => "regular question",     "ts" => now - 4000},
          %{"role" => "assistant", "content" => "regular answer",       "ts" => now - 3000},
          %{"role" => "user",      "content" => "/wiki xyz",           "ts" => now - 2000, "kind" => "command"},
          %{"role" => "assistant", "content" => "Indexed 1 chunk.",     "ts" => now - 1000, "kind" => "command_ack"},
          %{"role" => "user",      "content" => "next real question",   "ts" => now}
        ],
        "context" => %{}
      }

      msgs = Dmhai.Agent.ContextEngine.build_assistant_messages(session_data)

      contents = msgs |> Enum.map(fn m -> m[:content] || m["content"] end)

      # The two real user messages and the one real assistant reply pass through.
      assert Enum.any?(contents, &(&1 =~ "regular question"))
      assert Enum.any?(contents, &(&1 =~ "regular answer"))
      assert Enum.any?(contents, &(&1 =~ "next real question"))

      # The /wiki command + its ack are filtered out.
      refute Enum.any?(contents, fn c -> is_binary(c) and String.contains?(c, "/wiki xyz") end)
      refute Enum.any?(contents, fn c -> is_binary(c) and String.contains?(c, "Indexed 1 chunk") end)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────

  # Poll `session.messages` until it reaches `expected` length (or
  # the deadline elapses). Used by the async `/memo` tests — the
  # dispatch returns immediately and the ack/answer lands when the
  # background `Task.Supervisor` child finishes.
  defp wait_for_message_count(sid, expected, timeout_ms \\ 2_000) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait(sid, expected, deadline)
  end

  defp do_wait(sid, expected, deadline) do
    [[messages_json]] = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [sid]).rows
    msgs = Jason.decode!(messages_json || "[]")

    cond do
      length(msgs) >= expected ->
        msgs

      System.os_time(:millisecond) > deadline ->
        flunk("wait_for_message_count: got #{length(msgs)} of #{expected}, last msgs=#{inspect(msgs, limit: 5)}")

      true ->
        Process.sleep(20)
        do_wait(sid, expected, deadline)
    end
  end
end
