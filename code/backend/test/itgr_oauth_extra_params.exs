# Integration tests: provider-specific OAuth quirks ride through
# the auth URL (extra_auth_params) and the refresh body
# (extra_token_params).
#
# Run with:   MIX_ENV=test mix test test/itgr_oauth_extra_params.exs

defmodule Itgr.OAuthExtraParams do
  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Auth.OAuth2, OAuth.Catalog}
  alias DmhAi.Tools.AuthorizeService
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      """
      INSERT OR IGNORE INTO users (id, email, password_hash, role, created_at)
      VALUES (?,?,?,?,?)
      """,
      [user_id, "ep_#{user_id}@itgr.local", "", "user", now])
  end

  defp seed_session_with_task(user_id, session_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, "assistant", "[]", now, now])

    _ = DmhAi.Agent.Tasks.insert(%{
      user_id: user_id, session_id: session_id, task_type: "one_off", intvl_sec: 0,
      task_title: "t", task_spec: "t", task_status: "ongoing",
      time_to_pickup: now, language: "en", attachments: []
    })

    1
  end

  setup do
    query!(Repo, "DELETE FROM oauth_catalog", [])
    on_exit(fn -> query!(Repo, "DELETE FROM oauth_catalog", []) end)
    :ok
  end

  test "extra_auth_params land in the authorization URL" do
    user = uid(); sess = uid(); seed_user(user)
    n = seed_session_with_task(user, sess)

    {:ok, _} = Catalog.create(%{
      "slug" => "ep_test",
      "display_name" => "EP Test",
      "host_match" => "ep.example.test",
      "authorization_endpoint" => "https://auth.ep.example.test/o/auth",
      "token_endpoint"         => "https://auth.ep.example.test/o/token",
      "scopes_default" => ["a"],
      "client_id" => "cid",
      "client_secret" => "csec",
      "extra_auth_params"  => %{"access_type" => "offline", "prompt" => "consent"},
      "extra_token_params" => %{"audience" => "https://api.ep.example.test"},
      "enabled" => true
    })

    assert {:ok, %{auth_url: auth_url}} =
             AuthorizeService.execute(%{"target" => "ep_test"},
                                       %{user_id: user, session_id: sess, anchor_task_num: n})

    assert String.contains?(auth_url, "access_type=offline")
    assert String.contains?(auth_url, "prompt=consent")
    # extra_token_params don't ride on the auth URL — only on the
    # token-exchange body — so they must NOT appear here.
    refute String.contains?(auth_url, "audience=")
    # And the MCP-only `resource` must remain absent on the
    # generic OAuth flow.
    refute String.contains?(auth_url, "resource=")
  end

  test "extra_token_params persist on the cred payload at token-exchange time" do
    # Drives just the catalog.get_by_host + cred-payload assembly
    # since exchanging a real `code` would require a live server.
    {:ok, _} = Catalog.create(%{
      "slug" => "tk_test",
      "display_name" => "Token Test",
      "host_match" => "tk.example.test",
      "authorization_endpoint" => "https://auth.tk.example.test/o/auth",
      "token_endpoint"         => "https://auth.tk.example.test/o/token",
      "scopes_default" => [],
      "client_id" => "cid",
      "client_secret" => "csec",
      "extra_auth_params"  => %{},
      "extra_token_params" => %{"audience" => "https://api.tk.example.test"},
      "enabled" => true
    })

    assert %{extra_token_params: %{"audience" => "https://api.tk.example.test"}} =
             Catalog.get_by_host("tk.example.test")
  end

  test "OAuth2.init_flow with empty extra_auth_params produces a clean URL" do
    user = uid()
    seed_user(user)

    asm = %{
      authorization_endpoint: "https://example.test/auth",
      token_endpoint:         "https://example.test/token",
      scopes_supported:       ["s1"]
    }

    assert {:ok, %{auth_url: auth_url}} =
             OAuth2.init_flow(%{
               user_id:            user,
               session_id:         "sess_" <> uid(),
               anchor_task_id:     "task_" <> uid(),
               alias:              "test",
               canonical_resource: "test.example.test",
               server_url:         "https://test.example.test",
               asm:                asm,
               client_id:          "cid",
               client_secret:      "csec",
               redirect_uri:       "http://localhost:8080/oauth/callback",
               scopes:             ["s1"],
               flow_kind:          "oauth_service",
               extra_auth_params:  %{}
             })

    refute String.contains?(auth_url, "resource=")
    assert String.contains?(auth_url, "code_challenge=")
    assert String.contains?(auth_url, "scope=s1")
  end
end
