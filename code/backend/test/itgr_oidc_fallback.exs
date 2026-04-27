# Phase A bonus: `Auth.Discovery.fetch_asm/1` falls back to
# OpenID Connect Discovery (`.well-known/openid-configuration`)
# when RFC 8414's `.well-known/oauth-authorization-server` 404s.
# Without this, every OIDC-only provider — Google, Microsoft
# Entra, Okta, Auth0, Keycloak, AWS Cognito, Atlassian — gets
# bounced to the manual-OAuth form even though their metadata is
# right there.
#
# We probe Google's accounts.google.com (every Google product's
# OAuth) and Microsoft's login.microsoftonline.com (`common`
# tenant). Both serve OIDC discovery without auth and without IP
# allow-listing.
#
# Tagged `:network` — opt-in via `mix test --only network`.

defmodule Itgr.OidcFallback do
  use ExUnit.Case, async: true

  @moduletag :network
  @moduletag timeout: 30_000

  alias Dmhai.Auth.Discovery

  describe "OIDC fallback for fetch_asm/1" do
    test "Google's accounts.google.com — RFC 8414 404 → OIDC succeeds" do
      assert {:ok, asm} = Discovery.fetch_asm("https://accounts.google.com")

      assert is_binary(asm.authorization_endpoint)
      assert String.starts_with?(asm.authorization_endpoint, "https://accounts.google.com/")

      assert is_binary(asm.token_endpoint)
      assert String.starts_with?(asm.token_endpoint, "https://oauth2.googleapis.com/")

      # OAuth 2.1 mandates S256 PKCE; Google advertises it.
      assert "S256" in asm.code_challenge_methods_supported
    end

    test "Microsoft Entra (common tenant) — OIDC discovery via fallback" do
      assert {:ok, asm} =
               Discovery.fetch_asm("https://login.microsoftonline.com/common/v2.0")

      assert is_binary(asm.authorization_endpoint)
      assert String.starts_with?(asm.authorization_endpoint, "https://login.microsoftonline.com/")
      assert is_binary(asm.token_endpoint)
      # MS doesn't always advertise `code_challenge_methods_supported`
      # in v2.0 even though the AS accepts S256 in practice. parse_asm
      # accepts empty advertisement; we only flag a malformed AS when
      # the field is non-empty AND missing S256. Just verify the field
      # is present (could be a list).
      assert is_list(asm.code_challenge_methods_supported)
    end

    test "non-existent host — clean error, no exception" do
      assert {:error, _reason} =
               Discovery.fetch_asm("https://this-host-does-not-resolve-itgr.invalid")
    end
  end
end
