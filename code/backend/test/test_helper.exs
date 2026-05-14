ExUnit.start(timeout: 60_000)

# Seed the memo master key once for the whole suite. Tests don't go
# through the on-disk file path, so this avoids touching /data/secrets/
# (which may not be writable as the test user) and gives every test a
# stable, in-memory master key. See specs/memo_encryption.md.
DmhAi.MemoCrypto.MasterKey.put(:crypto.strong_rand_bytes(32))

# Skip `@tag :network` tests by default — they make real HTTP calls
# (LLM round-trips, MCP discovery, web fetches against live sites)
# and depend on credentials / external uptime / API-key budget. Run
# them explicitly with:
#   mix test --only network
ExUnit.configure(exclude: [:network, :known_design_bug])

# Profile-aware setup helpers used by `test/flows/*.exs`. Loaded once
# at suite start so the Mix.Task `flow` (and direct `mix test
# test/flows/...`) can call into `DmhAi.Test.FlowHelper.setup_profile/1`
# without each flow file requiring its own load_file/1 dance.
Code.require_file("flow_helper.exs", __DIR__)

defmodule T do
  @moduledoc "Shared test helpers."

  def uid, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  # A session_data map matching the shape returned by DB queries.
  def session_data(opts \\ []) do
    %{
      "id"       => Keyword.get(opts, :id, uid()),
      "user_id"  => Keyword.get(opts, :user_id, uid()),
      "mode"     => Keyword.get(opts, :mode, "confidant"),
      "messages" => Keyword.get(opts, :messages, []),
      "context"  => Keyword.get(opts, :context, nil)
    }
  end

  def user_msg(content),      do: %{"role" => "user",      "content" => content}
  def assistant_msg(content), do: %{"role" => "assistant", "content" => content}

  def conversation(n) do
    Enum.flat_map(1..n, fn i ->
      [user_msg("question #{i}"), assistant_msg("answer #{i}")]
    end)
  end

  # Install a synchronous LLM.call stub for the duration of a test.
  # `fun` receives (model_str, messages, opts) and returns
  # {:ok, text} | {:ok, {:tool_calls, calls}} | {:error, reason}.
  def stub_llm_call(fun) when is_function(fun, 3) do
    Application.put_env(:dmh_ai, :__llm_call_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__llm_call_stub__) end)
  end

  # Install a streaming LLM stub for the duration of a test.
  # `fun` receives (model_str, messages, reply_pid, opts) and returns
  # {:ok, text} | {:ok, {:tool_calls, calls}} | {:error, reason}.
  def stub_llm_stream(fun) when is_function(fun, 4) do
    Application.put_env(:dmh_ai, :__llm_stream_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__llm_stream_stub__) end)
  end

  # Install a stub at `LLM.do_stream_request/7` and `do_call_request/6`
  # — one layer DEEPER than `__llm_stream_stub__`. Lets a test
  # exercise the rotation/retry logic in `do_pool_stream` /
  # `do_pool_call` against deterministic per-account transport
  # outcomes. Stub fn:
  #   `(url, headers, body, %{kind: :stream | :call, model, …}) ->
  #     {:ok, text} | {:ok, {:tool_calls, calls}} |
  #     {:error, :rate_limited | :quota_exhausted | :server_error |
  #              {:rate_limited, ms} | term()}`
  def stub_llm_request(fun) when is_function(fun, 4) do
    Application.put_env(:dmh_ai, :__llm_request_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__llm_request_stub__) end)
  end

  # Install a stub for `DmhAi.Web.Search.call_search_engine/3` —
  # bypasses SearXNG + page-fetcher in confidant's web pre-step.
  # `fun` receives `(queries, category, opts)` and must return
  # `%{snippets: [map()], pages: [map()]}`.
  def stub_web_search(fun) when is_function(fun, 3) do
    Application.put_env(:dmh_ai, :__web_search_engine_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__web_search_engine_stub__) end)
  end

  # Install a stub for `DmhAi.Auth.OAuth2`'s outbound HTTP POSTs
  # (DCR + code/token exchange + refresh — single internal seam).
  # `fun` receives `(url, opts)` (the same args `Req.post/2` would
  # see) and must return one of:
  #   {:ok, %{status: integer, body: term}}
  #   {:error, reason}
  def stub_oauth2_http(fun) when is_function(fun, 2) do
    Application.put_env(:dmh_ai, :__oauth2_http_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__oauth2_http_stub__) end)
  end

  # Install a stub for `Tools.Registry.execute/3`. `fun` receives
  # (name, args, ctx) and must return:
  #   {:ok, result}      — fake the tool's output
  #   {:error, reason}   — fake an error path
  #   :passthrough       — let the real tool run
  # The :passthrough escape lets a flow fake one tool (e.g. run_script,
  # whose real path needs Docker) while letting bookkeeping verbs
  # (create_task / pickup_task / mark_done) hit the real Registry.
  def stub_tool(fun) when is_function(fun, 3) do
    Application.put_env(:dmh_ai, :__tool_execute_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__tool_execute_stub__) end)
  end

  # Install a stub for `DmhAi.MCP.Transport.request/3`. `fun` receives
  # (server_url, %{method, body, headers, auth, session_id}) and must
  # return one of:
  #   {:ok, body :: map(), %{session_id: String.t() | nil}}
  #   {:error, {:status, integer(), term()}}
  #   {:error, {:network, term()}}
  # Used by tests that drive the discovery cascade or per-tool calls
  # without spinning up a real MCP server.
  def stub_mcp_transport(fun) when is_function(fun, 2) do
    Application.put_env(:dmh_ai, :__mcp_transport_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__mcp_transport_stub__) end)
  end

  # Build a normalised tool-call list (as returned by LLM.normalize_tool_calls).
  def tool_call(name, args \\ %{}, id \\ nil) do
    %{"id" => id || uid(), "function" => %{"name" => name, "arguments" => args}}
  end

  def tool_call_with_sig(name, args \\ %{}) do
    %{"id" => uid(),
      "function" => %{"name" => name, "arguments" => args, "thought_signature" => "sig_#{uid()}"}}
  end

  # ─── Session walk: drive a multi-turn assistant session offline ──────────
  #
  # The shape that catches the bugs unit tests miss. Drive a sequence
  # of user messages through the live `UserAgent.dispatch_assistant/2`
  # path; for each message, the chain proceeds through a list of
  # turn responses you supply (`{:tool_calls, [...]}` or
  # `{:text, "..."}`). After each chain ends (signalled by a
  # `chain_end` SessionProgress row), the helper snapshots the
  # observable state and moves to the next user message.
  #
  # Examples of what walks catch that single-turn tests don't:
  #   * tool_history NOT carrying closed-task data into the next chain
  #   * FE polling termination on close-verb empty narration
  #   * retry-cap bounding an infinite-rotation loop on single-account pools
  #
  # Walk shape:
  #
  #     T.session_walk(user_id, session_id, [
  #       {"first user msg", [
  #          fn _msgs, _tools -> {:tool_calls, [T.tool_call("create_task", %{...})]} end,
  #          fn _msgs, _tools -> {:tool_calls, [T.tool_call("complete_task", %{"task_num" => 1})]} end,
  #          fn _msgs, _tools -> {:text, "Done."} end
  #       ]},
  #       {"follow-up", [
  #          fn _msgs, _tools -> {:text, "Cannot recall — call fetch_task(1)?"} end
  #       ]}
  #     ])
  #
  # Each turn fn receives the live messages list and tools list the
  # runtime is about to send to the LLM, so the test can assert on
  # what the model "saw" mid-flight (e.g. that closed-task tool
  # results are absent on the second user message).
  #
  # Returns a list of observation maps, one per user message:
  #
  #     [
  #       %{
  #         messages:        [...],   # session.messages snapshot
  #         tool_history:    [...],   # session.tool_history snapshot
  #         progress:        [...],   # session_progress rows for this session
  #         seen_messages:   [[...], [...], ...]  # the per-turn live messages list
  #       },
  #       ...
  #     ]
  @session_walk_chain_timeout_ms 6_000

  # Settle window after a chain_end before declaring the system idle.
  # Auto-pivot follow-ups (close-verb chain ends → GenServer fires
  # :auto_resume_assistant → silent turn spawns) run AFTER the first
  # chain_end. Snapshotting before they finish strands the test:
  # session.messages doesn't yet have what the user would see. Wait
  # for the GenServer's `current_task` slot to stay empty for this
  # window before snapshotting — that's "queue truly drained."
  @session_walk_settle_grace_ms 200
  @session_walk_settle_poll_ms 25

  def session_walk(user_id, session_id, walk) when is_list(walk) do
    alias DmhAi.Agent.{AssistantCommand, SessionProgress, UserAgent}
    alias DmhAi.Repo
    import Ecto.Adapters.SQL, only: [query!: 3]

    seen_per_turn_pid =
      :persistent_term.get({:session_walk_buffer, self()}, nil) ||
        spawn_link(fn -> seen_buffer_loop([]) end)

    :persistent_term.put({:session_walk_buffer, self()}, seen_per_turn_pid)

    Enum.map_reduce(walk, 0, fn {user_msg, turn_fns}, baseline_progress_id ->
      send(seen_per_turn_pid, {:reset, self()})
      assert_seen_buffer_ack()

      # The stub fn gets called once per LLM turn within this user
      # message. We track turn index in a per-process counter so the
      # walk's closure list rotates correctly.
      counter_key = {:walk_turn, self(), user_msg}
      Process.put(counter_key, 0)

      stub_llm_stream(fn _model, msgs, _reply_pid, opts ->
        idx = Process.get(counter_key, 0)
        Process.put(counter_key, idx + 1)

        send(seen_per_turn_pid, {:saw, msgs, Keyword.get(opts, :tools, [])})

        case Enum.at(turn_fns, idx) do
          nil ->
            raise "session_walk: ran out of turn fns for user_msg=#{inspect(user_msg)} at turn #{idx}; supply more"

          fun when is_function(fun, 2) ->
            case fun.(msgs, Keyword.get(opts, :tools, [])) do
              {:tool_calls, calls}      -> {:ok, {:tool_calls, calls}}
              {:text, text}             -> {:ok, text}
              {:error, _} = e           -> e
              other ->
                raise "session_walk: turn fn must return {:tool_calls, …} | {:text, …} | {:error, …}, got #{inspect(other)}"
            end
        end
      end)

      # Mirror the `Handlers.AgentChat.post_chat` path: persist the
      # user message to `session.messages` BEFORE dispatching the
      # chain. The handler does this in production; without the same
      # step in tests, `last_msgs` in `build_assistant_messages` is
      # empty and the LLM never sees the user's actual input.
      anchor_num = DmhAi.Agent.Anchor.task_num_for(session_id)
      user_message =
        case anchor_num do
          n when is_integer(n) -> %{role: "user", content: user_msg, task_num: n}
          _                     -> %{role: "user", content: user_msg}
        end

      {:ok, _user_ts} = DmhAi.Agent.UserAgentMessages.append(session_id, user_id, user_message)

      cmd = %AssistantCommand{
        type:             :chat,
        content:          user_msg,
        session_id:       session_id,
        reply_pid:        self(),
        attachment_names: [],
        files:            [],
        metadata:         %{}
      }

      :ok = UserAgent.dispatch_assistant(user_id, cmd)

      next_id = wait_for_chain_end(session_id, user_id, baseline_progress_id)

      %{rows: rows} =
        query!(Repo,
          "SELECT messages, tool_history FROM sessions WHERE id=?",
          [session_id])

      [[messages_json, tool_history_json]] = rows

      seen = seen_buffer_drain(seen_per_turn_pid)

      observation = %{
        messages:      Jason.decode!(messages_json || "[]"),
        tool_history:  Jason.decode!(tool_history_json || "[]"),
        progress:      SessionProgress.fetch_for_session(session_id, 0),
        seen_messages: seen
      }

      {observation, next_id}
    end)
    |> elem(0)
  end

  # Drive the chain to true idle. Two phases:
  #   1. Wait for the first `chain_end` / `chain_aborted` row after
  #      baseline — the user-initiated chain has produced its
  #      termination signal.
  #   2. Settle. A close-verb chain that auto-pivots queues a silent
  #      follow-up turn; it spawns AFTER the first chain_end lands.
  #      Wait until `UserAgent.current_turn_session_id(user_id)`
  #      stays nil for `@session_walk_settle_grace_ms`. That's the
  #      same "system idle for this user" view the FE eventually
  #      converges on after `/poll` notices `ChainInFlight` is clear.
  #
  # Returns the LATEST chain_end / chain_aborted id seen so the next
  # iteration's `baseline_id` excludes everything the system has
  # already produced for this user message (including auto-pivot
  # follow-ups).
  defp wait_for_chain_end(session_id, user_id, baseline_id) do
    deadline = System.os_time(:millisecond) + @session_walk_chain_timeout_ms

    _first_id = wait_for_first_chain_end(session_id, baseline_id, deadline)
    drain_until_idle(user_id, deadline, nil)
    latest_chain_end_id(session_id, baseline_id) || raise(
      "session_walk: lost track of chain_end after settle"
    )
  end

  defp wait_for_first_chain_end(session_id, baseline_id, deadline) do
    alias DmhAi.Agent.SessionProgress

    rows = SessionProgress.fetch_for_session(session_id, baseline_id)

    case Enum.find(rows, fn r -> r.kind in ["chain_end", "chain_aborted"] end) do
      %{id: id} ->
        id

      _ ->
        if System.os_time(:millisecond) > deadline do
          raise "session_walk: chain didn't end within #{@session_walk_chain_timeout_ms}ms"
        else
          Process.sleep(20)
          wait_for_first_chain_end(session_id, baseline_id, deadline)
        end
    end
  end

  # Block until the GenServer's current_task slot has been empty for
  # `@session_walk_settle_grace_ms` continuously. `idle_since` is
  # the wall-clock ts when we last observed idleness; resets to nil
  # any time a chain re-enters flight. Returns `:ok` on settle or
  # `:timeout` (the test's content asserts then catch the failure
  # with a clearer message than a raised timeout would).
  defp drain_until_idle(user_id, deadline, idle_since) do
    alias DmhAi.Agent.UserAgent

    cond do
      System.os_time(:millisecond) > deadline ->
        :timeout

      UserAgent.current_turn_session_id(user_id) != nil ->
        Process.sleep(@session_walk_settle_poll_ms)
        drain_until_idle(user_id, deadline, nil)

      is_nil(idle_since) ->
        Process.sleep(@session_walk_settle_poll_ms)
        drain_until_idle(user_id, deadline, System.os_time(:millisecond))

      System.os_time(:millisecond) - idle_since >= @session_walk_settle_grace_ms ->
        :ok

      true ->
        Process.sleep(@session_walk_settle_poll_ms)
        drain_until_idle(user_id, deadline, idle_since)
    end
  end

  defp latest_chain_end_id(session_id, baseline_id) do
    alias DmhAi.Agent.SessionProgress

    SessionProgress.fetch_for_session(session_id, baseline_id)
    |> Enum.filter(fn r -> r.kind in ["chain_end", "chain_aborted"] end)
    |> Enum.map(& &1.id)
    |> case do
      []  -> nil
      ids -> Enum.max(ids)
    end
  end

  defp seen_buffer_loop(state) do
    receive do
      {:saw, msgs, tools} ->
        seen_buffer_loop([%{msgs: msgs, tools: tools} | state])

      {:reset, caller} ->
        send(caller, :seen_buffer_reset_ack)
        seen_buffer_loop([])

      {:drain, caller} ->
        send(caller, {:seen_buffer, Enum.reverse(state)})
        seen_buffer_loop([])
    end
  end

  defp assert_seen_buffer_ack do
    receive do
      :seen_buffer_reset_ack -> :ok
    after
      1_000 -> raise "session_walk: seen_buffer didn't ack reset"
    end
  end

  defp seen_buffer_drain(pid) do
    send(pid, {:drain, self()})

    receive do
      {:seen_buffer, list} -> list
    after
      1_000 -> []
    end
  end

  # ─── Mock vendor MCP server helpers ───────────────────────────────────
  #
  # Shared by every per-connector integration test that exercises the
  # real Caller path against `DmhAi.Connectors.Mock.VendorMCPServer`.
  # Each helper is idempotent + handles its own on_exit cleanup so
  # tests stay readable.

  @doc """
  Start a Mock VendorMCPServer instance on a free port with the
  given fixtures map. Returns `%{pid, url, port}`. The mock is
  shut down on test exit.
  """
  def start_mock_vendor(instance, fixtures)
      when is_binary(instance) and is_map(fixtures) do
    {:ok, sock} = :gen_tcp.listen(0, [:binary])
    {:ok, {_addr, port}} = :inet.sockname(sock)
    :gen_tcp.close(sock)

    {:ok, pid} = DmhAi.Connectors.Mock.VendorMCPServer.start_link(
      instance: instance,
      port:     port,
      fixtures: fixtures
    )

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    %{pid: pid, url: "http://127.0.0.1:#{port}/", port: port}
  end

  @doc """
  Seed the three DB rows that let `MCP.Client.call_tool/4` reach a
  mock vendor MCP server for `user_id`:

    * `authorized_services` row (alias=slug, server_url=mock_url)
    * `user_credentials` at `oauth:<slug>` (the Caller's pre-check)
    * `user_credentials` at `mcp:<canonical>` (the bearer token MCP.Client uses)

  Returns `:ok`. Cleanup is the test's responsibility — usually
  via the broader `on_exit` that DELETEs the user.
  """
  def seed_mcp_authorization(user_id, slug, canonical, mock_url)
      when is_binary(user_id) and is_binary(slug) and is_binary(canonical) and is_binary(mock_url) do
    :ok = DmhAi.MCP.Registry.authorize(user_id, slug, canonical, mock_url, nil)

    :ok = DmhAi.Auth.Credentials.save(user_id, "oauth:" <> slug, "oauth2",
                                      %{"access_token" => "test-precheck-token"},
                                      account: "")

    :ok = DmhAi.Auth.Credentials.save(user_id, "mcp:" <> canonical, "oauth2_mcp",
                                      %{"access_token" => "test-mcp-bearer-token"},
                                      account: "",
                                      expires_at: :os.system_time(:millisecond) + 3_600_000)

    :ok
  end

  @doc """
  Create a transient user for an integration test. Returns the
  generated user_id; the row is DELETEd on_exit along with its
  credentials, authorized_services, and audit_log entries.
  """
  def transient_user(opts \\ []) do
    import Ecto.Adapters.SQL, only: [query!: 3]

    user_id = uid()
    org_id  = Keyword.get(opts, :org_id, DmhAi.Constants.default_org_id())
    role    = Keyword.get(opts, :org_role, "member")

    query!(DmhAi.Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "txuser-#{user_id}@test.local", "TxUser", "x:y", "user",
       org_id, role, :os.system_time(:second)])

    ExUnit.Callbacks.on_exit(fn ->
      query!(DmhAi.Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])
      query!(DmhAi.Repo, "DELETE FROM authorized_services WHERE user_id=?", [user_id])
      query!(DmhAi.Repo, "DELETE FROM audit_log WHERE user_id=?", [user_id])
      query!(DmhAi.Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    user_id
  end

  # ─── Memo encryption helpers ──────────────────────────────────────────────
  #
  # Memo writes/reads use a master-key-wrapped MMK persisted in
  # `users.memo_wrapped_mmk` (see specs/memo_encryption.md). Tests
  # that exercise memo paths should call `install_memo_key/1` to
  # seed both the user row and the wrap. The master key itself is
  # pre-seeded once per suite in test_helper.exs.

  @doc "Generate a fresh 32-byte MMK suitable for direct ingest tests."
  def memo_test_key, do: :crypto.strong_rand_bytes(32)

  @doc """
  Make `user_id` ready for memo ops:
    * upsert a placeholder `users` row if absent (so `ensure_memo_key`
      has a row to UPDATE),
    * call `UserAgent.ensure_memo_key/1` which generates a fresh MMK
      and persists a V2 master-key-wrapped row,
    * register cleanup to wipe the cache + DB row on test exit.

  Returns the resulting 32-byte MMK so tests that bypass the tools
  layer can encrypt directly via `MemoCrypto.encrypt_chunk/4`.
  """
  def install_memo_key(user_id) do
    import Ecto.Adapters.SQL, only: [query!: 3]

    %{rows: existing} =
      query!(DmhAi.Repo, "SELECT id FROM users WHERE id=?", [user_id])

    inserted_here? =
      case existing do
        [_ | _] ->
          false

        _ ->
          # Use a unique fake email to avoid the UNIQUE(email) collision.
          email = "test-#{user_id}@test.invalid"
          query!(DmhAi.Repo, """
          INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at)
          VALUES (?,?,?,?,?,?,?,?)
          """, [user_id, email, "test", "x:y", "user",
                DmhAi.Constants.default_org_id(), "member", :os.system_time(:second)])
          true
      end

    {:ok, mmk} = DmhAi.Agent.UserAgent.ensure_memo_key(user_id)

    ExUnit.Callbacks.on_exit(fn ->
      DmhAi.Agent.UserAgent.wipe_memo_key(user_id)

      if inserted_here? do
        query!(DmhAi.Repo, "DELETE FROM users WHERE id=?", [user_id])
      end
    end)

    mmk
  end
end
