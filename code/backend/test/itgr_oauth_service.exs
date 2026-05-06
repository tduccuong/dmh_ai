# Integration tests: generic OAuth service authorization
# (Tools.AuthorizeService + oauth_catalog).
#
# Coverage:
#   - Catalog get_by_slug, get_by_host (longest-suffix match), URL.
#   - Tool's already-authorized shortcut when a fresh token exists.
#   - Tool fires init_flow with flow_kind="oauth_service" and returns
#     `needs_auth` + auth_url on cold start.
#   - Tool error when target doesn't match any catalog entry.
#   - The auth URL omits the MCP-only `resource` param.
#   - Tokens persisted at "oauth:<host>" with kind "oauth2_service".
#   - Police gate keeps authorize_service in @gated_tools.
#
# Run with:   MIX_ENV=test mix test test/itgr_oauth_service.exs

defmodule Itgr.OAuthService do
  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Auth.Credentials, OAuth.Catalog, Tools.AuthorizeService}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      """
      INSERT OR IGNORE INTO users (id, email, password_hash, role, created_at)
      VALUES (?,?,?,?,?)
      """,
      [user_id, "auth_#{user_id}@itgr.local", "", "user", now])
  end

  defp seed_session_with_task(user_id, session_id, task_num \\ 1) do
    now = System.os_time(:millisecond)
    msgs = [%{"role" => "user", "content" => "x", "ts" => now}]

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, "assistant", Jason.encode!(msgs), now, now])

    _task_id = DmhAi.Agent.Tasks.insert(%{
      user_id:        user_id,
      session_id:     session_id,
      task_type:      "one_off",
      intvl_sec:      0,
      task_title:     "test",
      task_spec:      "test",
      task_status:    "ongoing",
      time_to_pickup: now,
      language:       "en",
      attachments:    []
    })

    task_num
  end

  defp seed_catalog(slug, host_match, opts \\ []) do
    now = System.os_time(:millisecond)
    enabled = if Keyword.get(opts, :enabled, true), do: 1, else: 0

    query!(Repo,
      """
      INSERT OR REPLACE INTO oauth_catalog
        (slug, display_name, host_match,
         authorization_endpoint, token_endpoint,
         scopes_default, client_id, client_secret,
         enabled, created_ts, updated_ts)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
      """,
      [
        slug, "Service " <> slug, host_match,
        "https://auth.example.test/o/auth",
        "https://auth.example.test/o/token",
        Jason.encode!(["scope_a", "scope_b"]),
        "client_id_" <> slug,
        "client_secret_" <> slug,
        enabled,
        now,
        now
      ])
  end

  defp clear_catalog do
    query!(Repo, "DELETE FROM oauth_catalog", [])
  end

  defp ctx_for(user_id, session_id, task_num) do
    %{user_id: user_id, session_id: session_id, anchor_task_num: task_num}
  end

  setup do
    clear_catalog()
    on_exit(fn -> clear_catalog() end)
    :ok
  end

  # ─── Catalog lookup ────────────────────────────────────────────────────────

  describe "Catalog" do
    test "get_by_slug returns the row when enabled" do
      seed_catalog("svc1", "api.example.com")
      assert %{slug: "svc1", host_match: "api.example.com"} = Catalog.get_by_slug("svc1")
    end

    test "get_by_slug returns nil for disabled rows" do
      seed_catalog("svc2", "api2.example.com", enabled: false)
      assert Catalog.get_by_slug("svc2") == nil
    end

    test "get_by_host matches exact host" do
      seed_catalog("svc3", "exact.example.com")
      assert %{slug: "svc3"} = Catalog.get_by_host("exact.example.com")
    end

    test "get_by_host matches subdomain via suffix" do
      seed_catalog("svc4", "example.com")
      assert %{slug: "svc4"} = Catalog.get_by_host("api.calendar.example.com")
    end

    test "get_by_host longest-prefix wins" do
      seed_catalog("broad", "example.com")
      seed_catalog("narrow", "api.example.com")

      assert %{slug: "narrow"} = Catalog.get_by_host("api.example.com")
      assert %{slug: "broad"} = Catalog.get_by_host("www.example.com")
    end

    test "get_by_host accepts a full URL" do
      seed_catalog("svc5", "example.com")
      assert %{slug: "svc5"} = Catalog.get_by_host("https://api.example.com/v1/foo")
    end

    test "get_by_host returns nil when no match" do
      seed_catalog("svc6", "example.com")
      assert Catalog.get_by_host("https://other.test/x") == nil
    end
  end

  # ─── Tool: target outside the catalog ──────────────────────────────────────

  test "authorize_service: target not in catalog → honest error to model" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)

    # Seed at least one row so the resolver's "no service matches"
    # branch fires with candidates, not the "catalog is empty"
    # branch. Both branches surface honest errors; the candidates
    # variant is the more common production case.
    seed_catalog("seeded_other", "seeded-other.test")

    assert {:error, msg} =
             AuthorizeService.execute(%{"target" => "totally-unknown-host.test"},
                                       ctx_for(user, sess, n))

    assert msg =~ "No service in the OAuth catalog matches"
    assert msg =~ "totally-unknown-host.test"
    # Closest configured services are surfaced for the model to
    # relay to the user.
    assert msg =~ "slug=`seeded_other`"
    # Guidance: don't guess, ask the user OR ask for a URL.
    assert msg =~ "ask them to pick"
  end

  test "authorize_service: target not in catalog AND catalog empty → honest empty-catalog error" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)

    assert {:error, msg} =
             AuthorizeService.execute(%{"target" => "totally-unknown-host.test"},
                                       ctx_for(user, sess, n))

    assert msg =~ "No OAuth services are configured"
    assert msg =~ "browser_task"
    assert msg =~ "web_search"
  end

  # ─── Tool: cold start fires the OAuth flow ─────────────────────────────────

  test "authorize_service: no stored token → needs_auth + auth_url; flow_kind oauth_service persisted" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)
    seed_catalog("svc_a", "service-a.test")

    assert {:ok, %{status: "needs_auth", auth_url: auth_url, alias: "svc_a"}} =
             AuthorizeService.execute(%{"target" => "svc_a"}, ctx_for(user, sess, n))

    assert is_binary(auth_url) and auth_url != ""
    # Generic-OAuth flows MUST NOT include the RFC 8707 `resource` param
    # — that's MCP-only and breaks providers like Google / Slack / GitHub.
    refute String.contains?(auth_url, "resource=")
    # But scope and PKCE must be present.
    assert String.contains?(auth_url, "scope=")
    assert String.contains?(auth_url, "code_challenge=")
    assert String.contains?(auth_url, "code_challenge_method=S256")

    %{rows: [[fk]]} =
      query!(Repo, "SELECT flow_kind FROM pending_oauth_states WHERE user_id=?", [user])

    assert fk == "oauth_service"
  end

  # ─── Tool: already-authorized shortcut ─────────────────────────────────────

  test "authorize_service: existing fresh oauth2_service cred → returns {status: \"authorized\"}" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)
    seed_catalog("svc_b", "service-b.test")

    # Pre-seed a non-expired oauth2_service credential at oauth:<host>.
    one_hour = 3_600_000
    Credentials.save(
      user,
      "oauth:service-b.test",
      "oauth2_service",
      %{"access_token" => "tkn_abc", "refresh_token" => "rfr_abc"},
      account: "",
      notes: "test",
      expires_at: System.os_time(:millisecond) + one_hour
    )

    assert {:ok, %{status: "authorized", alias: "svc_b", cred_target: target}} =
             AuthorizeService.execute(%{"target" => "svc_b"}, ctx_for(user, sess, n))

    assert target == "oauth:service-b.test"
  end

  # ─── Tool: force_new bypasses the shortcut even when creds exist ──────────

  test "authorize_service: force_new=true triggers OAuth flow even with existing creds" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)
    seed_catalog("svc_force", "service-force.test")

    # Pre-seed an existing valid credential. Without force_new the
    # tool would short-circuit to {status: "authorized"}.
    one_hour = 3_600_000
    Credentials.save(
      user,
      "oauth:service-force.test",
      "oauth2_service",
      %{"access_token" => "old_tkn", "refresh_token" => "old_rfr"},
      account: "alice@example.com",
      notes: "test",
      expires_at: System.os_time(:millisecond) + one_hour
    )

    # force_new=true: should ignore the existing row and return needs_auth.
    assert {:ok, %{status: "needs_auth", alias: "svc_force", auth_url: auth_url, message: msg}} =
             AuthorizeService.execute(
               %{"target" => "svc_force", "force_new" => true},
               ctx_for(user, sess, n))

    assert is_binary(auth_url) and auth_url != ""
    assert msg =~ "add a new"
  end

  test "authorize_service: force_new omitted defaults to existing-cred shortcut" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)
    seed_catalog("svc_default", "service-default.test")

    one_hour = 3_600_000
    Credentials.save(
      user,
      "oauth:service-default.test",
      "oauth2_service",
      %{"access_token" => "t", "refresh_token" => "r"},
      account: "alice@example.com",
      notes: "test",
      expires_at: System.os_time(:millisecond) + one_hour
    )

    assert {:ok, %{status: "authorized"}} =
             AuthorizeService.execute(%{"target" => "svc_default"}, ctx_for(user, sess, n))
  end

  test "authorize_service: force_new=false explicitly behaves like omitted" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)
    seed_catalog("svc_fn_false", "service-fn-false.test")

    one_hour = 3_600_000
    Credentials.save(
      user,
      "oauth:service-fn-false.test",
      "oauth2_service",
      %{"access_token" => "t", "refresh_token" => "r"},
      account: "",
      notes: "test",
      expires_at: System.os_time(:millisecond) + one_hour
    )

    assert {:ok, %{status: "authorized"}} =
             AuthorizeService.execute(
               %{"target" => "svc_fn_false", "force_new" => false},
               ctx_for(user, sess, n))
  end

  # ─── Tool: target accepted as URL (host extracted) ─────────────────────────

  test "authorize_service: full URL target → catalog lookup by host suffix" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)
    seed_catalog("svc_c", "service-c.test")

    assert {:ok, %{status: "needs_auth", alias: "svc_c"}} =
             AuthorizeService.execute(%{"target" => "https://api.service-c.test/v1/things"},
                                       ctx_for(user, sess, n))
  end

  # ─── Tool: missing context ─────────────────────────────────────────────────

  test "authorize_service: missing user_id rejected" do
    assert {:error, msg} =
             AuthorizeService.execute(%{"target" => "any.test"}, %{session_id: "x", anchor_task_num: 1})
    assert msg =~ "user_id"
  end

  test "authorize_service: empty target rejected" do
    user = uid(); seed_user(user)
    assert {:error, msg} =
             AuthorizeService.execute(%{"target" => ""},
                                       %{user_id: user, session_id: "x", anchor_task_num: 1})
    assert msg =~ "non-empty"
  end

  # ─── Tool registration ────────────────────────────────────────────────────

  test "authorize_service is in Tools.Registry's catalog (visible to the LLM)" do
    names = DmhAi.Tools.Registry.names()
    assert "authorize_service" in names
  end
end
