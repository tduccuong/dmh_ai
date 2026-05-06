# Session-walk regression: when a stored OAuth token is rejected
# server-side (401 mid-call), the model uses the credential's
# `auth_target` field to re-auth via authorize_service.
#
# Why this exists:
#   * The bug: model held an oauth2_service credential, used it,
#     got 401, then called authorize_service(target: "oauth:googleapis.com")
#     because that's the credential's `target`. The catalog's
#     resolver doesn't know about credential-vault prefixes
#     (`oauth:`, `mcp:`), so it rejected the input.
#   * The fix: credentials carry `auth_target` (catalog slug). The
#     model copies it verbatim into authorize_service.
#
# This walk drives that exact production flow with stubbed LLM
# responses and asserts the model receives auth_target on
# lookup_creds, then routes it correctly to authorize_service.

defmodule Itgr.SessionWalkDeadTokenReauth do
  use ExUnit.Case, async: false

  alias DmhAi.Auth.Credentials
  alias DmhAi.OAuth.Catalog
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "swdtr_#{user_id}@itgr.local", "user", now])
  end

  defp insert_session(session_id, user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, "assistant", "[]", now, now])
  end

  defp seed_catalog(slug, host) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    INSERT OR REPLACE INTO oauth_catalog
      (slug, display_name, host_match,
       authorization_endpoint, token_endpoint,
       scopes_default, client_id, client_secret,
       extra_auth_params, extra_token_params,
       userinfo_endpoint, userinfo_field_path,
       enabled, created_ts, updated_ts)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
    """, [
      slug,
      "Test Service " <> slug,
      host,
      "https://example.test/o/oauth2/v2/auth",
      "https://example.test/token",
      Jason.encode!([]),
      "fake_client_id",
      "fake_client_secret",
      Jason.encode!(%{}),
      Jason.encode!(%{}),
      nil,
      nil,
      now, now
    ])

    on_exit(fn -> query!(Repo, "DELETE FROM oauth_catalog WHERE slug=?", [slug]) end)
  end

  test "lookup_creds surfaces auth_target; model uses it on 401 to re-auth via authorize_service" do
    user_id    = uid()
    session_id = uid()
    seed_user(user_id)
    insert_session(session_id, user_id)

    slug = "swdtr-google-" <> uid()
    host = "swdtr-google-" <> uid() <> ".test"
    seed_catalog(slug, host)

    # Pre-seed an oauth2_service credential carrying auth_target.
    # In production this is populated by finalize_oauth_service at
    # OAuth-callback time; here we write it directly to mirror what
    # an existing credential row would look like.
    one_hour = 3_600_000
    Credentials.save(
      user_id,
      "oauth:" <> host,
      "oauth2_service",
      %{
        "access_token"  => "stale_token",
        "refresh_token" => "rfr_xxx",
        "host_match"    => host,
        "auth_target"   => slug
      },
      account: "alice@example.com",
      notes: "test",
      expires_at: System.os_time(:millisecond) + one_hour
    )

    # Capture the auth_target value the model sees on lookup_creds.
    # The walk fns close over a process dict slot so the second
    # turn can use the value the first turn observed.
    captured = :ets.new(:swdtr_capture, [:set, :public])

    [_obs1] =
      T.session_walk(user_id, session_id, [
        {"check my data", [
          fn _msgs, _tools ->
            {:tool_calls, [
              T.tool_call("create_task", %{
                "task_type"  => "one_off",
                "task_title" => "check svc",
                "task_spec"  => "use the service",
                "language"   => "en"
              })
            ]}
          end,
          fn _msgs, _tools ->
            {:tool_calls, [
              T.tool_call("lookup_creds", %{"target" => "oauth:" <> host})
            ]}
          end,
          fn msgs, _tools ->
            # The previous tool result (lookup_creds) is the most
            # recent `tool` message in `msgs`. Parse it and capture
            # auth_target — the value the model is supposed to copy
            # forward.
            result_json =
              msgs
              |> Enum.reverse()
              |> Enum.find(fn m -> (m[:role] || m["role"]) == "tool" end)
              |> case do
                %{} = msg -> msg[:content] || msg["content"]
                _ -> nil
              end

            case Jason.decode(result_json || "{}") do
              {:ok, %{"credentials" => [first | _]}} ->
                :ets.insert(captured, {:auth_target, first["auth_target"]})

              _ ->
                :ets.insert(captured, {:auth_target, nil})
            end

            # Model now calls authorize_service with the captured
            # auth_target.
            [{:auth_target, at}] = :ets.lookup(captured, :auth_target)

            {:tool_calls, [
              T.tool_call("authorize_service", %{
                "target"    => at,
                "force_new" => true
              })
            ]}
          end,
          fn _msgs, _tools ->
            # authorize_service returned needs_auth + auth_url; model
            # would normally relay the URL and end the chain. Use a
            # close-verb to terminate so the walk completes cleanly.
            {:tool_calls, [T.tool_call("cancel_task", %{"task_num" => 1})]}
          end
        ]}
      ])

    [{:auth_target, observed}] = :ets.lookup(captured, :auth_target)

    assert observed == slug,
           "lookup_creds should surface auth_target=<catalog slug>; got #{inspect(observed)}"

    # The catalog resolved the slug — the OAuth flow initiated, NOT
    # the "no service matches" error path. Easiest invariant to
    # check: a pending_oauth_states row was inserted with this
    # user_id and our catalog row's host_match.
    %{rows: pending_rows} =
      query!(Repo,
        "SELECT canonical_resource FROM pending_oauth_states WHERE user_id=? ORDER BY created_at DESC LIMIT 1",
        [user_id])

    assert pending_rows != [],
           "authorize_service(target: <auth_target>) should have inserted a pending_oauth_states row"

    [[canonical]] = pending_rows
    assert canonical == host,
           "pending OAuth state should target the catalog row's host_match"
  end
end
