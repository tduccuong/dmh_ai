# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F15 — OAuth authorize then use service.
#
# The OAuth dance has three observable steps from BE's POV:
#
#   1. `OAuth2.init_flow/1` — issues a `state` token, persists a
#      `pending_oauth_states` row keyed by it (PKCE verifier, ASM,
#      client metadata), returns the auth URL the FE redirects to.
#   2. Provider redirects back to `/oauth/callback?state=…&code=…`.
#   3. `OAuth2.complete_flow/2` — looks up the state, exchanges the
#      code for tokens at `asm.token_endpoint`, deletes the pending
#      row, returns `{:ok, %{… tokens: %{access_token, …}}}`. The
#      callback handler then persists tokens via
#      `Credentials.save/5` and (for MCP) attaches services to the
#      anchor task.
#
# F15 covers steps 2-3 — the load-bearing token-exchange path. The
# token endpoint's HTTP POST is faked via `T.stub_oauth2_http/1`
# (the new `__oauth2_http_stub__` env hook in `Auth.OAuth2`). Step 1
# is mostly DB plumbing already covered by `init_flow/1`'s call
# sites; the test seeds a `pending_oauth_states` row directly to
# focus on the exchange.

defmodule DmhAi.Flows.F15OauthAuthorizeUse do
  use ExUnit.Case, async: false

  alias DmhAi.Auth.OAuth2
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F15"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F15")
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
      query!(Repo, "DELETE FROM pending_oauth_states WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM tasks WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  describe "OAuth2.complete_flow/2" do
    test "happy path — code exchanges for tokens; pending row consumed",
         %{user_id: user_id, session_id: session_id} do
      task_id = "task-#{T.uid()}"
      state = "state-#{T.uid()}"
      pkce_verifier = "verifier-#{T.uid()}"
      code  = "auth-code-#{T.uid()}"

      asm = %{
        "issuer"                 => "https://oauth.test",
        "authorization_endpoint" => "https://oauth.test/authorize",
        "token_endpoint"         => "https://oauth.test/token"
      }

      seed_pending(state, user_id, session_id, task_id, asm,
        pkce_verifier: pkce_verifier)

      stub_calls = :counters.new(1, [:atomics])

      T.stub_oauth2_http(fn url, opts ->
        :counters.add(stub_calls, 1, 1)
        assert url == "https://oauth.test/token",
               "stub got URL=#{url}; expected the token endpoint"

        # `exchange_code/3` posts a form body — verify the
        # spec-mandated fields are present (proves PKCE round-trip
        # + the redirect_uri agreement).
        form = Keyword.fetch!(opts, :form)
        form_map = Map.new(form, fn {k, v} -> {to_string(k), to_string(v)} end)

        assert form_map["grant_type"]    == "authorization_code"
        assert form_map["code"]          == code
        assert form_map["client_id"]     == "test-client-id"
        assert form_map["code_verifier"] == pkce_verifier
        assert is_binary(form_map["redirect_uri"]) and form_map["redirect_uri"] != ""

        {:ok,
         %{status: 200,
           body: %{
             "access_token"  => "AT-stub-#{T.uid()}",
             "refresh_token" => "RT-stub-#{T.uid()}",
             "token_type"    => "Bearer",
             "expires_in"    => 3600,
             "scope"         => "read write"
           }}}
      end)

      assert {:ok, result} = OAuth2.complete_flow(state, code)

      assert result.user_id == user_id
      assert result.session_id == session_id
      assert result.anchor_task_id == task_id
      assert result.alias == "test-alias"
      assert result.canonical_resource == "https://res.test"
      assert result.server_url == "https://res.test/api"
      assert result.flow_kind == "mcp"

      tokens = result.tokens
      assert is_binary(tokens.access_token) and String.starts_with?(tokens.access_token, "AT-stub-")
      assert is_binary(tokens.refresh_token) and String.starts_with?(tokens.refresh_token, "RT-stub-")
      assert tokens.token_type == "Bearer"
      assert tokens.scope == "read write"
      assert is_integer(tokens.expires_at) and tokens.expires_at > System.os_time(:millisecond),
             "expires_at should be a future ms timestamp; got: #{inspect(tokens.expires_at)}"

      # Pending row is consumed exactly once.
      %{rows: rows} =
        query!(Repo, "SELECT 1 FROM pending_oauth_states WHERE state=?", [state])
      assert rows == [],
             "pending_oauth_states row must be deleted after a successful exchange"

      assert :counters.get(stub_calls, 1) == 1,
             "token endpoint should be hit exactly once; got: #{:counters.get(stub_calls, 1)}"
    end

    test "expired state → :expired (no token call attempted)",
         %{user_id: user_id, session_id: session_id} do
      state = "expired-#{T.uid()}"

      seed_pending(state, user_id, session_id, "task-#{T.uid()}", default_asm(),
        expires_at: System.os_time(:millisecond) - 1_000)

      stub_calls = :counters.new(1, [:atomics])
      T.stub_oauth2_http(fn _, _ ->
        :counters.add(stub_calls, 1, 1)
        flunk("token endpoint must NOT be called when state is already expired")
      end)

      assert {:error, :expired} = OAuth2.complete_flow(state, "any-code")

      # The expired row is also cleaned up so a future state collision can't
      # accidentally reuse it.
      %{rows: rows} =
        query!(Repo, "SELECT 1 FROM pending_oauth_states WHERE state=?", [state])
      assert rows == [],
             "expired pending row should be deleted on the :expired path"

      assert :counters.get(stub_calls, 1) == 0
    end

    test "unknown state → :not_found",
         %{} do
      assert {:error, :not_found} =
               OAuth2.complete_flow("never-issued-#{T.uid()}", "any-code")
    end

    test "token endpoint returns non-200 → token_exchange_failed surfaces status",
         %{user_id: user_id, session_id: session_id} do
      state = "fail-#{T.uid()}"

      seed_pending(state, user_id, session_id, "task-#{T.uid()}", default_asm())

      T.stub_oauth2_http(fn _url, _opts ->
        {:ok,
         %{status: 401,
           body: %{"error" => "invalid_grant", "error_description" => "code reused"}}}
      end)

      assert {:error, {:token_exchange_failed, 401, body}} =
               OAuth2.complete_flow(state, "stale-code")

      assert is_map(body)
      assert body["error"] == "invalid_grant"

      # Failed exchange does NOT consume the pending row — the user
      # might retry the callback with a different code if their
      # provider supports it. This matches production behavior at
      # `oauth2.ex` line 304-306 (the {:error, _} arm leaves
      # `delete_pending/1` unrun).
      %{rows: rows} =
        query!(Repo, "SELECT 1 FROM pending_oauth_states WHERE state=?", [state])
      assert rows == [[1]],
             "pending row should survive a failed token exchange so a retry can find it"
    end

    test "malformed token response → :malformed_token_response",
         %{user_id: user_id, session_id: session_id} do
      state = "malformed-#{T.uid()}"
      seed_pending(state, user_id, session_id, "task-#{T.uid()}", default_asm())

      T.stub_oauth2_http(fn _, _ ->
        {:ok, %{status: 200, body: %{"weird" => "no access_token"}}}
      end)

      assert {:error, {:malformed_token_response, _}} =
               OAuth2.complete_flow(state, "code-#{T.uid()}")
    end
  end

  describe "GET /oauth/callback (HTTP route)" do
    test "code+state → 200 HTML; token persisted to user_credentials",
         %{user_id: user_id, session_id: session_id} do
      task_id = "task-#{T.uid()}"
      state = "state-#{T.uid()}"

      asm = %{
        "issuer"                 => "https://oauth.test",
        "authorization_endpoint" => "https://oauth.test/authorize",
        "token_endpoint"         => "https://oauth.test/token"
      }

      # For `flow_kind="oauth_service"`, `canonical_resource` is the
      # bare host pattern; the callback handler stores the credential
      # at target `"oauth:" <> host_match` (data.ex:1069). Don't pre-
      # prefix here — that would produce `oauth:oauth:…`.
      seed_pending(state, user_id, session_id, task_id, asm,
        flow_kind: "oauth_service",
        canonical_resource: "api.example.test",
        server_url: "https://api.example.test")

      access_token = "AT-svc-#{T.uid()}"

      T.stub_oauth2_http(fn _url, _opts ->
        {:ok,
         %{status: 200,
           body: %{
             "access_token" => access_token,
             "token_type"   => "Bearer",
             "expires_in"   => 1800
           }}}
      end)

      # `finalize_oauth_service` fires `:auto_resume_assistant` after
      # persisting the credential — see data.ex:1083. The async
      # chain calls `LLM.stream` and would tape-miss without a stub
      # in place. Provide a permissive ack stub; the chain runs and
      # we drain it below before letting setup's on_exit fire.
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)
      T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
        {:ok, "OAuth flow completed."}
      end)

      conn =
        :get
        |> Plug.Test.conn("/oauth/callback?state=#{URI.encode_www_form(state)}&code=cb-code")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> DmhAi.Router.call(DmhAi.Router.init([]))

      assert conn.status == 200,
             "successful callback should render a 200 HTML page; got #{conn.status} body=#{conn.resp_body}"
      assert conn.resp_body =~ "Authorized"

      # Pending row consumed.
      %{rows: pending_rows} =
        query!(Repo, "SELECT 1 FROM pending_oauth_states WHERE state=?", [state])
      assert pending_rows == []

      # Credential persisted under the canonical_resource. For
      # `flow_kind="oauth_service"`, target prefix is `oauth:`.
      %{rows: cred_rows} =
        query!(Repo,
          "SELECT kind, payload FROM user_credentials WHERE user_id=? AND target=?",
          [user_id, "oauth:api.example.test"])

      assert match?([[_kind, _payload]], cred_rows),
             "expected exactly one credential row at target=oauth:api.example.test for the authed user; got: #{inspect(cred_rows)}"

      [[kind, payload_json]] = cred_rows
      assert kind == "oauth2_service"

      payload = Jason.decode!(payload_json)
      assert payload["access_token"] == access_token,
             "persisted access_token must round-trip from the stubbed token endpoint"

      # Drain the auto-resume chain that `finalize_oauth_service`
      # fired before letting setup's on_exit run — otherwise the
      # async chain races cleanup and trips the LLMStub tape-miss
      # guard if the next test changes stubs.
      :ok = wait_until_idle(user_id, 6_000)
    end

    test "missing code → 400",
         %{} do
      conn =
        :get
        |> Plug.Test.conn("/oauth/callback?state=anything")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> DmhAi.Router.call(DmhAi.Router.init([]))

      assert conn.status == 400
    end

    test "unknown state → 404",
         %{} do
      T.stub_oauth2_http(fn _, _ ->
        flunk("unknown-state path must NOT call the token endpoint")
      end)

      conn =
        :get
        |> Plug.Test.conn("/oauth/callback?state=ghost&code=anything")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> DmhAi.Router.call(DmhAi.Router.init([]))

      assert conn.status == 404
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp default_asm,
    do: %{
      "issuer"                 => "https://oauth.test",
      "authorization_endpoint" => "https://oauth.test/authorize",
      "token_endpoint"         => "https://oauth.test/token"
    }

  defp seed_pending(state, user_id, session_id, anchor_task_id, asm, opts \\ []) do
    now = System.os_time(:millisecond)
    expires_at = Keyword.get(opts, :expires_at, now + 5 * 60_000)

    query!(Repo, """
    INSERT INTO pending_oauth_states
      (state, user_id, session_id, anchor_task_id, alias, canonical_resource,
       server_url, pkce_verifier, client_id, client_secret, asm_json, scopes,
       redirect_uri, flow_kind, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      state, user_id, session_id, anchor_task_id,
      Keyword.get(opts, :alias, "test-alias"),
      Keyword.get(opts, :canonical_resource, "https://res.test"),
      Keyword.get(opts, :server_url, "https://res.test/api"),
      Keyword.get(opts, :pkce_verifier, "verifier-#{T.uid()}"),
      Keyword.get(opts, :client_id, "test-client-id"),
      Keyword.get(opts, :client_secret, ""),
      Jason.encode!(asm),
      Jason.encode!(Keyword.get(opts, :scopes, [])),
      Keyword.get(opts, :redirect_uri, "https://app.test/oauth/callback"),
      Keyword.get(opts, :flow_kind, "mcp"),
      now, expires_at
    ])

    :ok
  end

  defp wait_until_idle(user_id, timeout_ms) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until_idle(user_id, deadline, nil)
  end

  defp do_wait_until_idle(user_id, deadline, idle_since) do
    grace_ms = 200

    cond do
      System.os_time(:millisecond) > deadline ->
        :timeout

      DmhAi.Agent.UserAgent.current_turn_session_id(user_id) != nil ->
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
