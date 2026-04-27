# End-to-end Phase B (manual OAuth, #149) verification against the
# tiny Go mock at `mock_mcp/server`. The mock implements just the
# OAuth 2.1 authorization-code grant and refresh-token grant against
# a hardcoded client `app.test123` / `test_secret_123`. It listens
# on a random port (printed on stdout); we spawn it, parse the port,
# drive the BE through:
#
#   finalize_oauth_setup       — synth ASM, save oauth_client, init_flow
#   GET <auth_url> (no follow) — mock returns 302 with code + state
#   complete_flow(state, code) — mock returns access_token + refresh_token
#
# Then we assert the credential is materialised at
# `mcp:<canonical>` with the right tokens. (We do NOT exercise the
# downstream MCP handshake — the mock has no MCP endpoint by design;
# `/itgr_open_mcp.exs` covers the no-auth handshake side. Together
# they bracket Phase B end-to-end.)
#
# Tagged `:network` so default `mix test` skips it. Run with:
#   mix test test/itgr_oauth_bitrix_mock.exs --only network

defmodule Itgr.OauthBitrixMock do
  use ExUnit.Case, async: false

  @moduletag :network
  @moduletag timeout: 30_000

  alias Dmhai.Auth.{Credentials, OAuth2}
  alias Dmhai.Handlers.Data
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @mock_binary Path.expand("../../../mock_mcp/server", __DIR__)

  # ─── mock subprocess plumbing ────────────────────────────────────────────

  defp start_mock! do
    File.exists?(@mock_binary) ||
      flunk("mock binary not found at #{@mock_binary} — build it from mock_mcp/")

    port_io =
      Port.open({:spawn_executable, @mock_binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        line: 4096
      ])

    port_num = wait_for_port_line(port_io, 5_000)

    {port_io, port_num}
  end

  defp wait_for_port_line(port_io, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_port_line(port_io, deadline)
  end

  defp do_wait_for_port_line(port_io, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Port.close(port_io)
      flunk("mock server didn't print a port within timeout")
    end

    receive do
      {^port_io, {:data, {:eol, line}}} ->
        case Regex.run(~r{Server running on http://localhost:(\d+)}, line) do
          [_, p] -> String.to_integer(p)
          _      -> do_wait_for_port_line(port_io, deadline)
        end

      {^port_io, {:exit_status, status}} ->
        flunk("mock exited prematurely with status #{status}")
    after
      remaining ->
        Port.close(port_io)
        flunk("mock server didn't print a port within timeout")
    end
  end

  defp stop_mock(port_io) do
    if Port.info(port_io) != nil do
      try do
        {:os_pid, os_pid} = Port.info(port_io, :os_pid)
        System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true)
      catch
        _, _ -> :ok
      end
      try do
        Port.close(port_io)
      catch
        _, _ -> :ok
      end
    end
  end

  # ─── DB fixture helpers ──────────────────────────────────────────────────

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "bitrix_#{user_id}@itgr.local", "user", now]
    )
  end

  defp seed_session(sid, user_id) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT OR IGNORE INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [sid, user_id, "assistant", "[]", now, now]
    )
  end

  defp seed_anchor_task(user_id, sid) do
    Dmhai.Agent.Tasks.insert(
      user_id: user_id,
      session_id: sid,
      task_title: "bitrix mock test",
      task_spec:  "drive Phase B against mock_mcp"
    )
  end

  # ─── tests ───────────────────────────────────────────────────────────────

  setup_all do
    {port_io, port} = start_mock!()
    on_exit(fn -> stop_mock(port_io) end)
    {:ok, mock_port: port}
  end

  setup ctx do
    user_id = T.uid()
    sid = "bitrix_mock_" <> T.uid()
    seed_user(user_id)
    seed_session(sid, user_id)
    anchor_task_id = seed_anchor_task(user_id, sid)

    base = "http://localhost:#{ctx.mock_port}"

    setup_payload = %{
      "auth_method"        => "oauth",
      "alias"               => "bitrix24_mock",
      "server_url"          => "#{base}/mcp",
      "canonical_resource"  => "#{base}/mcp",
      "anchor_task_id"      => anchor_task_id
    }

    form_values = %{
      "authorization_endpoint" => "#{base}/oauth/authorize",
      "token_endpoint"         => "#{base}/oauth/token",
      "scopes"                 => "app",
      "client_id"              => "app.test123",
      "client_secret"          => "test_secret_123"
    }

    {:ok,
     user_id: user_id,
     sid: sid,
     anchor_task_id: anchor_task_id,
     base: base,
     setup_payload: setup_payload,
     form_values: form_values}
  end

  describe "Phase B end-to-end against mock_mcp/server" do
    test "init_flow → authorize redirect → complete_flow returns tokens", ctx do
      # ── 1. finalize_oauth_setup
      assert {:ok, %{alias: "bitrix24_mock", auth_url: auth_url}} =
               Data.finalize_oauth_setup(ctx.setup_payload, ctx.form_values, ctx.user_id, ctx.sid)

      # The authorize URL must point at the mock and carry the right OAuth2 params.
      uri = URI.parse(auth_url)
      assert uri.host == "localhost"
      assert uri.path == "/oauth/authorize"

      qp = URI.decode_query(uri.query || "")
      state = qp["state"]
      assert is_binary(state) and state != ""
      assert qp["client_id"] == "app.test123"
      assert qp["response_type"] == "code"
      assert qp["code_challenge_method"] == "S256"
      assert qp["redirect_uri"] =~ "/oauth/callback"

      # ── 2. follow the authorize URL once with redirects DISABLED so we
      #       can read the Location header the mock emits.
      {:ok, %Req.Response{status: 302, headers: headers}} =
        Req.get(auth_url, redirect: false, retry: false, receive_timeout: 5_000)

      location =
        headers
        |> Enum.find(fn {k, _} -> String.downcase(to_string(k)) == "location" end)
        |> case do
          {_, v} when is_binary(v)  -> v
          {_, [v | _]}              -> v
          _                          -> flunk("mock didn't return a Location header on authorize redirect")
        end

      redirect_uri = URI.parse(location)
      qpr = URI.decode_query(redirect_uri.query || "")

      code = qpr["code"]
      assert is_binary(code) and code != ""
      assert qpr["state"] == state

      # ── 3. complete_flow exchanges the code at the mock's /oauth/token,
      #       returns the AS metadata + tokens.
      assert {:ok, completion} = OAuth2.complete_flow(state, code)

      assert completion.user_id == ctx.user_id
      assert completion.session_id == ctx.sid
      assert completion.anchor_task_id == ctx.anchor_task_id
      assert completion.alias == "bitrix24_mock"
      assert completion.canonical_resource == ctx.setup_payload["canonical_resource"]
      assert completion.server_url == ctx.setup_payload["server_url"]

      tokens = completion.tokens
      assert is_binary(tokens.access_token) and String.length(tokens.access_token) >= 32
      assert is_binary(tokens.refresh_token) and String.length(tokens.refresh_token) >= 32
      assert tokens.token_type == "Bearer" or is_nil(tokens.token_type)

      # ── 4. The pending_oauth_states row was consumed (single-use state).
      r = query!(Repo, "SELECT count(*) FROM pending_oauth_states WHERE state=?", [state])
      assert [[0]] = r.rows
    end

    test "wrong client_secret on the same flow → token exchange fails", ctx do
      bad_form = Map.put(ctx.form_values, "client_secret", "totally_wrong")

      {:ok, %{auth_url: auth_url}} =
        Data.finalize_oauth_setup(ctx.setup_payload, bad_form, ctx.user_id, ctx.sid)

      state = URI.parse(auth_url).query |> URI.decode_query() |> Map.fetch!("state")

      {:ok, %Req.Response{status: 302, headers: headers}} =
        Req.get(auth_url, redirect: false, retry: false)

      location =
        headers
        |> Enum.find(fn {k, _} -> String.downcase(to_string(k)) == "location" end)
        |> elem(1)
        |> case do
          v when is_binary(v) -> v
          [v | _]              -> v
        end

      code = URI.parse(location).query |> URI.decode_query() |> Map.fetch!("code")

      # Mock's /oauth/token rejects the wrong secret with 401.
      assert {:error, {:token_exchange_failed, 401, _}} =
               OAuth2.complete_flow(state, code)
    end

    test "expired authorize code is rejected (mock TTL is 5 minutes; we just check the not-found path with a fake code)", ctx do
      {:ok, %{auth_url: auth_url}} =
        Data.finalize_oauth_setup(ctx.setup_payload, ctx.form_values, ctx.user_id, ctx.sid)

      state = URI.parse(auth_url).query |> URI.decode_query() |> Map.fetch!("state")

      # Don't visit the authorize URL — invent a never-issued code.
      assert {:error, {:token_exchange_failed, 400, _}} =
               OAuth2.complete_flow(state, "never_issued_code_" <> T.uid())
    end

    test "refresh_token grant via OAuth2.refresh/2 round-trips tokens", ctx do
      # First do a full happy-path exchange so we have a real refresh
      # token to feed into refresh/2.
      {:ok, %{auth_url: auth_url}} =
        Data.finalize_oauth_setup(ctx.setup_payload, ctx.form_values, ctx.user_id, ctx.sid)

      state = URI.parse(auth_url).query |> URI.decode_query() |> Map.fetch!("state")

      {:ok, %Req.Response{status: 302, headers: headers}} =
        Req.get(auth_url, redirect: false, retry: false)

      location =
        headers
        |> Enum.find(fn {k, _} -> String.downcase(to_string(k)) == "location" end)
        |> elem(1)
        |> case do
          v when is_binary(v) -> v
          [v | _]              -> v
        end

      code = URI.parse(location).query |> URI.decode_query() |> Map.fetch!("code")

      {:ok, completion} = OAuth2.complete_flow(state, code)

      target = "mcp:" <> completion.canonical_resource

      Credentials.save(ctx.user_id, target, "oauth2_mcp", %{
        "access_token"       => completion.tokens.access_token,
        "refresh_token"      => completion.tokens.refresh_token,
        "token_type"         => completion.tokens.token_type,
        "scope"              => completion.tokens.scope,
        "server_url"         => completion.server_url,
        "alias"              => completion.alias,
        "canonical_resource" => completion.canonical_resource,
        "asm_json"           => Jason.encode!(completion.asm),
        "client_id"          => "app.test123",
        "client_secret"      => "test_secret_123"
      })

      original = Credentials.lookup(ctx.user_id, target)

      assert {:ok, refreshed} = OAuth2.refresh(ctx.user_id, target)
      assert refreshed.payload["access_token"] != original.payload["access_token"]
      assert is_binary(refreshed.payload["refresh_token"])
      assert String.length(refreshed.payload["refresh_token"]) >= 32
    end
  end
end
