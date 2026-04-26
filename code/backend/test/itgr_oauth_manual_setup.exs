# Integration tests for the OAuth-manual finalization path
# (`Dmhai.Handlers.Data.finalize_oauth_setup/4`), the last piece of
# Phase B (#149).
#
# Covers:
#   1. Validation: required fields (auth_endpoint, token_endpoint,
#      client_id, anchor_task_id) and the optional client_secret.
#   2. Synthesised ASM shape that goes into `pending_oauth_states` —
#      atom-keyed, S256 PKCE, auth + token endpoints from the form.
#   3. Manual `oauth_client:<auth_endpoint>` credential row written
#      so `finalize_connection` (in the OAuth callback) can fold it
#      into the token payload at refresh time.
#   4. `init_flow` is invoked with the right `redirect_uri` shape
#      (`<oauth_redirect_base_url>/oauth/callback`) and returns an
#      auth_url the caller can hand to the user.
#
# Pure offline — no LLM calls and no real network. The only HTTP
# call init_flow could make is into Req's pending-state INSERT
# (which is a SQLite write, not HTTP).

defmodule Itgr.OauthManualSetup do
  use ExUnit.Case, async: false

  alias Dmhai.Auth.{Credentials, OAuth2}
  alias Dmhai.Handlers.Data
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "test_#{user_id}@itgr.local", "user", now]
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
      task_title: "connect bitrix24",
      task_spec: "connect to bitrix24 via manual OAuth"
    )
  end

  defp setup_payload(anchor_task_id, opts \\ []) do
    %{
      "auth_method"        => "oauth",
      "alias"               => Keyword.get(opts, :alias, "bitrix24"),
      "server_url"          => Keyword.get(opts, :server_url, "https://example.bitrix24.com/mcp"),
      "canonical_resource"  => Keyword.get(opts, :canonical_resource, "https://example.bitrix24.com/mcp"),
      "anchor_task_id"      => anchor_task_id
    }
  end

  defp valid_form_values do
    %{
      "authorization_endpoint" => "https://example.bitrix24.com/oauth/authorize/",
      "token_endpoint"         => "https://example.bitrix24.com/oauth/token/",
      "scopes"                 => "crm task user",
      "client_id"              => "local.123abc",
      "client_secret"          => "shhhh"
    }
  end

  setup do
    user_id = T.uid()
    sid     = "oauth_manual_" <> T.uid()
    seed_user(user_id)
    seed_session(sid, user_id)
    anchor_task_id = seed_anchor_task(user_id, sid)
    {:ok, user_id: user_id, sid: sid, anchor_task_id: anchor_task_id}
  end

  # ─── happy path ─────────────────────────────────────────────────────────

  describe "happy path" do
    test "returns {:ok, %{alias, auth_url}} with a usable authorization URL", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = valid_form_values()

      assert {:ok, %{alias: alias_, auth_url: auth_url}} =
               Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)

      assert alias_ == "bitrix24"
      assert is_binary(auth_url) and auth_url != ""
      assert String.starts_with?(auth_url, "https://example.bitrix24.com/oauth/authorize/")

      # Required OAuth 2.1 query params landed on the URL.
      uri  = URI.parse(auth_url)
      qp   = URI.decode_query(uri.query || "")

      assert qp["response_type"]         == "code"
      assert qp["client_id"]             == "local.123abc"
      assert qp["code_challenge_method"] == "S256"
      assert is_binary(qp["code_challenge"]) and qp["code_challenge"] != ""
      assert is_binary(qp["state"])           and qp["state"]         != ""
      assert qp["resource"]              == "https://example.bitrix24.com/mcp"

      # Scopes joined with space per OAuth.
      assert qp["scope"] == "crm task user"

      # Redirect URI follows the same base URL the auto path uses.
      assert qp["redirect_uri"] =~ "/oauth/callback"
    end

    test "saves the manual oauth_client credential keyed by auth_endpoint", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = valid_form_values()

      assert {:ok, _} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)

      cred = Credentials.lookup(ctx.user_id, "oauth_client:" <> values["authorization_endpoint"])
      assert cred != nil
      assert cred.kind == "oauth_client"
      assert cred.payload["client_id"]     == "local.123abc"
      assert cred.payload["client_secret"] == "shhhh"
    end

    test "client_secret omitted is allowed (public OAuth client)", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = Map.put(valid_form_values(), "client_secret", "")

      assert {:ok, _} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)

      cred = Credentials.lookup(ctx.user_id, "oauth_client:" <> values["authorization_endpoint"])
      assert cred.payload["client_secret"] == nil
    end

    test "scopes empty is allowed (returns no `scope` query param)", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = Map.put(valid_form_values(), "scopes", "")

      assert {:ok, %{auth_url: auth_url}} =
               Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)

      qp = URI.parse(auth_url).query |> URI.decode_query()
      refute Map.has_key?(qp, "scope")
    end

    test "writes a pending_oauth_states row with the synthesized ASM", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = valid_form_values()

      {:ok, %{auth_url: auth_url}} =
        Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)

      state = URI.parse(auth_url).query |> URI.decode_query() |> Map.fetch!("state")

      r = query!(Repo,
            "SELECT user_id, anchor_task_id, alias, canonical_resource, asm_json, redirect_uri, client_id, client_secret FROM pending_oauth_states WHERE state=?",
            [state]
          )

      assert [[uid, atid, alias_, canonical, asm_json, redirect_uri, cid, csecret]] = r.rows
      assert uid == ctx.user_id
      assert atid == ctx.anchor_task_id
      assert alias_ == "bitrix24"
      assert canonical == "https://example.bitrix24.com/mcp"
      assert cid == "local.123abc"
      assert csecret == "shhhh"
      assert redirect_uri =~ "/oauth/callback"

      asm = Jason.decode!(asm_json)
      assert asm["authorization_endpoint"] == "https://example.bitrix24.com/oauth/authorize/"
      assert asm["token_endpoint"]         == "https://example.bitrix24.com/oauth/token/"
      assert asm["code_challenge_methods_supported"] == ["S256"]
      assert asm["scopes_supported"]                  == ["crm", "task", "user"]
    end
  end

  # ─── validation ─────────────────────────────────────────────────────────

  describe "validation" do
    test "missing authorization_endpoint → {:error, _}", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = Map.put(valid_form_values(), "authorization_endpoint", "")

      assert {:error, msg} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)
      assert msg =~ "Authorization URL"
    end

    test "missing token_endpoint → {:error, _}", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = Map.put(valid_form_values(), "token_endpoint", "")

      assert {:error, msg} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)
      assert msg =~ "Token URL"
    end

    test "missing client_id → {:error, _}", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = Map.put(valid_form_values(), "client_id", "")

      assert {:error, msg} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)
      assert msg =~ "Client ID"
    end

    test "missing anchor_task_id in setup payload → {:error, _}", ctx do
      setup_p = setup_payload(ctx.anchor_task_id) |> Map.delete("anchor_task_id")
      values  = valid_form_values()

      assert {:error, msg} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)
      assert msg =~ "anchor_task_id"
    end

    test "validation failures don't write any state (no oauth_client row, no pending_oauth_states row)", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = Map.put(valid_form_values(), "authorization_endpoint", "")

      assert {:error, _} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)

      cred = Credentials.lookup(ctx.user_id, "oauth_client:" <> values["authorization_endpoint"])
      assert cred == nil

      r = query!(Repo,
            "SELECT count(*) FROM pending_oauth_states WHERE user_id=?",
            [ctx.user_id]
          )

      assert [[0]] = r.rows
    end

    test "trim handles whitespace-only fields as empty", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = Map.put(valid_form_values(), "client_id", "   ")

      assert {:error, msg} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)
      assert msg =~ "Client ID"
    end

    test "nil values map handled (e.g. submit with empty body)", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = %{
        "authorization_endpoint" => nil,
        "token_endpoint"         => nil,
        "client_id"              => nil
      }

      assert {:error, _} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)
    end
  end

  # ─── reuse: subsequent connect for same AS reuses the saved client ─────

  describe "client reuse" do
    test "second call with same auth_endpoint upserts the same oauth_client row", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = valid_form_values()

      assert {:ok, _} = Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)
      first = Credentials.lookup(ctx.user_id, "oauth_client:" <> values["authorization_endpoint"])

      # Update the secret on second submit; the upsert should reflect it.
      values2 = Map.put(values, "client_secret", "rotated")
      assert {:ok, _} = Data.finalize_oauth_setup(setup_p, values2, ctx.user_id, ctx.sid)
      second = Credentials.lookup(ctx.user_id, "oauth_client:" <> values["authorization_endpoint"])

      assert first.id == second.id  # same row, upserted
      assert second.payload["client_secret"] == "rotated"
    end
  end

  # ─── one full round-trip through OAuth2.complete_flow's pending row ─────
  #
  # Doesn't exchange a code with the AS (no live network), but verifies
  # the pending row created by finalize_oauth_setup has the exact fields
  # complete_flow's fetch_pending reads — catches schema-shape regressions.

  describe "pending state shape ↔ complete_flow contract" do
    test "complete_flow can read back the manual-init pending row", ctx do
      setup_p = setup_payload(ctx.anchor_task_id)
      values  = valid_form_values()

      {:ok, %{auth_url: auth_url}} =
        Data.finalize_oauth_setup(setup_p, values, ctx.user_id, ctx.sid)

      state = URI.parse(auth_url).query |> URI.decode_query() |> Map.fetch!("state")

      # Calling complete_flow with a fake code will fail at exchange_code
      # (network step). What we want to verify here is that the
      # PRE-exchange validation passes — i.e. the pending row is
      # well-formed enough for complete_flow to find + parse it.
      result = OAuth2.complete_flow(state, "fake_code_that_wont_be_accepted")

      # Must NOT be :not_found — that would mean the row insert was wrong.
      refute match?({:error, :not_found}, result),
             "complete_flow couldn't find the pending row written by finalize_oauth_setup"

      # Should reach exchange_code (token endpoint POST). Will fail
      # with either token_exchange_failed (real AS rejects fake code)
      # OR network (test env can't reach the endpoint). Either is
      # downstream of the contract we're verifying.
      case result do
        {:error, {:token_exchange_failed, _, _}}  -> :ok
        {:error, {:network, _}}                    -> :ok
        {:error, :expired}                         -> :ok  # in case it slept
        other ->
          flunk("unexpected complete_flow result: #{inspect(other)}")
      end
    end
  end
end
