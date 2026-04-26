# Phase C / Chunk 2 — proactive auto-refresh on lookup
# (`Auth.OAuth2.lookup_with_refresh/2`).
#
# The wrapper saves a 401 round-trip when the access token is known
# stale: it reads `is_expired` straight from the credential record
# and fires `OAuth2.refresh/2` ahead of any MCP call.
#
# Behaviors covered (offline, no real HTTP — refresh's network call
# is the one piece we can't stub here without invasive mocks; we
# instead set up payloads that don't trigger refresh, OR we plant a
# refresh that fails at the AS to verify the failure path).
#
# ─── Refresh's HTTP step ─────
# `OAuth2.refresh/2` uses `Req.post` against `asm[:token_endpoint]`.
# In the failure-path tests we point token_endpoint at a non-routable
# loopback so the call resolves quickly with `{:error, {:network, _}}`,
# then verify the wrapper's downstream behavior (registry flips to
# `needs_auth`, error returned to caller) without depending on a real
# OAuth provider.

defmodule Itgr.OauthLookupWithRefresh do
  use ExUnit.Case, async: false

  alias Dmhai.Auth.{Credentials, OAuth2}
  alias Dmhai.MCP.Registry
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "test_#{user_id}@itgr.local", "user", now]
    )
  end

  defp save_oauth2_mcp(user_id, target, payload, expires_at) do
    Credentials.save(user_id, target, "oauth2_mcp", payload, expires_at: expires_at)
  end

  defp save_api_key_mcp(user_id, target, payload) do
    Credentials.save(user_id, target, "api_key_mcp", payload, expires_at: nil)
  end

  defp valid_oauth_payload(opts \\ []) do
    %{
      "access_token"       => Keyword.get(opts, :access_token, "AT_" <> uid()),
      "refresh_token"      => Keyword.get(opts, :refresh_token, "RT_" <> uid()),
      "token_type"         => "Bearer",
      "scope"              => "read",
      "server_url"         => "https://example.com/mcp",
      "alias"              => Keyword.get(opts, :alias, "svc"),
      "canonical_resource" => Keyword.get(opts, :canonical, "https://example.com/mcp"),
      "asm_json"           =>
        Jason.encode!(%{
          # Unrouteable token endpoint — refresh fails fast with a
          # network error instead of hitting the live internet.
          "token_endpoint" => "https://127.0.0.1:1/token",
          "issuer"          => "https://as.example.com"
        }),
      "client_id"     => "client_id_x",
      "client_secret" => "client_secret_x"
    }
  end

  setup do
    user_id = uid()
    seed_user(user_id)
    {:ok, user_id: user_id}
  end

  # ─── happy path: not-expired returns as-is, no refresh ────────────────

  describe "non-expired oauth2_mcp creds" do
    test "returned as-is, no refresh attempted", %{user_id: user_id} do
      target = "mcp:" <> "https://example.com/svc_" <> uid()
      future = System.os_time(:millisecond) + 60 * 60 * 1000  # +1h
      save_oauth2_mcp(user_id, target, valid_oauth_payload(), future)

      assert {:ok, cred} = OAuth2.lookup_with_refresh(user_id, target)
      assert cred.kind == "oauth2_mcp"
      assert cred.is_expired == false
      assert cred.payload["access_token"] != ""
    end
  end

  # ─── non-oauth creds: pass through unchanged ─────────────────────────

  describe "non-oauth2_mcp creds" do
    test "api_key_mcp credential passes through (no expiry semantics)", %{user_id: user_id} do
      target = "mcp:" <> "https://example.com/api_" <> uid()
      save_api_key_mcp(user_id, target, %{
        "api_key"            => "secret_key",
        "api_key_header"     => "Authorization",
        "alias"              => "k",
        "canonical_resource" => "https://example.com/api"
      })

      assert {:ok, cred} = OAuth2.lookup_with_refresh(user_id, target)
      assert cred.kind == "api_key_mcp"
    end
  end

  # ─── missing credentials ─────────────────────────────────────────────

  describe "missing credentials" do
    test "returns {:error, :missing}", %{user_id: user_id} do
      assert {:error, :missing} =
               OAuth2.lookup_with_refresh(user_id, "mcp:never_seen_" <> uid())
    end
  end

  # ─── expired oauth2_mcp creds: refresh path ──────────────────────────
  #
  # We can't stub the HTTP refresh round-trip cheaply, but the wrapper
  # routes through `refresh/2` which uses Req.post against
  # `asm[:token_endpoint]`. We point that at a non-routable loopback
  # port and verify the failure path: the wrapper marks the registry
  # `needs_auth` and surfaces `{:refresh_failed, _}` to the caller.

  describe "expired oauth2_mcp creds → refresh path" do
    setup %{user_id: user_id} do
      alias_ = "svc_" <> uid()
      canonical = "https://example.com/mcp/" <> alias_
      target = "mcp:" <> canonical

      Registry.authorize(user_id, alias_, canonical, canonical, %{issuer: "https://as.example.com"})

      past = System.os_time(:millisecond) - 60 * 1000  # 1 min ago
      save_oauth2_mcp(user_id, target, valid_oauth_payload(alias: alias_, canonical: canonical), past)

      {:ok, alias: alias_, canonical: canonical, target: target}
    end

    test "expired credential → fires refresh; on refresh failure flips registry to needs_auth", ctx do
      assert Registry.find_authorized(ctx.user_id, ctx.alias).status == "authorized"

      assert {:error, {:refresh_failed, _reason}} =
               OAuth2.lookup_with_refresh(ctx.user_id, ctx.target)

      # Side effect: registry flipped on the failure path.
      assert Registry.find_authorized(ctx.user_id, ctx.alias).status == "needs_auth"
    end

    test "the credential row is left intact for inspection / re-auth", ctx do
      assert {:error, _} = OAuth2.lookup_with_refresh(ctx.user_id, ctx.target)
      cred = Credentials.lookup(ctx.user_id, ctx.target)
      assert cred != nil
      assert cred.kind == "oauth2_mcp"
    end

    test "no associated registry row → graceful no-op on the registry flip", %{user_id: user_id} do
      # Save an expired oauth2_mcp credential at a target whose
      # canonical doesn't match any authorized_services row (unlikely
      # in normal flow; defensive). Wrapper still surfaces the
      # refresh_failed error; the side-effect lookup just no-ops.
      orphan_canonical = "https://orphan.example/mcp/" <> uid()
      orphan_target = "mcp:" <> orphan_canonical
      past = System.os_time(:millisecond) - 60 * 1000
      save_oauth2_mcp(user_id, orphan_target, valid_oauth_payload(canonical: orphan_canonical), past)

      assert {:error, {:refresh_failed, _}} =
               OAuth2.lookup_with_refresh(user_id, orphan_target)

      # No spurious authorized_services row created.
      assert Registry.find_authorized_by_resource(user_id, orphan_canonical) == nil
    end
  end

  # ─── target shape doesn't match `mcp:<canonical>` ────────────────────

  describe "non-mcp credential targets" do
    test "ad-hoc credential at a non-`mcp:` target with refresh failure does not touch registry", %{user_id: user_id} do
      target = "adhoc_oauth_" <> uid()
      past   = System.os_time(:millisecond) - 60 * 1000
      save_oauth2_mcp(user_id, target, valid_oauth_payload(), past)

      assert {:error, {:refresh_failed, _}} = OAuth2.lookup_with_refresh(user_id, target)
      # The mark_resource_needs_auth helper is `mcp:` prefix gated.
      # No registry row at all for a non-`mcp:` target — and the
      # call is a no-op rather than a crash.
    end
  end
end
