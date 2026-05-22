# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.OAuthIdentityTest do
  @moduledoc """
  Pins the per-connector `OAuthIdentity.fetch_userinfo/1` contract.

  Each connector that captures identity at OAuth time implements the
  callback. HubSpot uses its token-introspect endpoint
  (`/oauth/v1/access-tokens/<TOKEN>`, token in path); the OIDC trio
  (Google Workspace, M365, Calendly) delegate to the shared OIDC
  helper. Stripe doesn't implement the callback at all — `account`
  stays empty cleanly.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.{HubSpot, GoogleWorkspace, M365, Calendly}
  alias DmhAi.Connectors.OAuthIdentity

  setup do
    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__hubspot_introspect_stub__)
      Application.delete_env(:dmh_ai, :__oidc_userinfo_stub__)
    end)
    :ok
  end

  describe "HubSpot.fetch_userinfo/1" do
    test "extracts user + user_id from /oauth/v1/access-tokens response" do
      Application.put_env(:dmh_ai, :__hubspot_introspect_stub__, fn url ->
        assert url == "https://api.hubapi.com/oauth/v1/access-tokens/" <>
                       "FAKE" <> "_TOKEN"
        {:ok, %{status: 200, body: %{
          "hub_id"     => 12345,
          "app_id"     => 99,
          "user_id"    => 67890,
          "user"       => "tduccuong@example.com",
          "expires_in" => 1800
        }}}
      end)

      assert {:ok, %{email: "tduccuong@example.com", id: "67890"}} =
               HubSpot.fetch_userinfo("FAKE" <> "_TOKEN")
    end

    test "tolerates a response missing user_id (still surfaces email)" do
      Application.put_env(:dmh_ai, :__hubspot_introspect_stub__, fn _ ->
        {:ok, %{status: 200, body: %{"user" => "ops@example.com"}}}
      end)

      assert {:ok, %{email: "ops@example.com"}} =
               HubSpot.fetch_userinfo("FAKE" <> "_TOKEN")
    end

    test "propagates HTTP errors with body" do
      Application.put_env(:dmh_ai, :__hubspot_introspect_stub__, fn _ ->
        {:ok, %{status: 401, body: %{"message" => "token invalid"}}}
      end)

      assert {:error, {:http, 401, %{"message" => "token invalid"}}} =
               HubSpot.fetch_userinfo("FAKE" <> "_TOKEN")
    end

    test "propagates transport errors" do
      Application.put_env(:dmh_ai, :__hubspot_introspect_stub__, fn _ ->
        {:error, %{reason: :timeout}}
      end)

      assert {:error, {:transport, %{reason: :timeout}}} =
               HubSpot.fetch_userinfo("FAKE" <> "_TOKEN")
    end
  end

  describe "OIDC connectors via shared helper" do
    test "Google Workspace extracts the email at the standard OIDC path" do
      Application.put_env(:dmh_ai, :__oidc_userinfo_stub__, fn url, headers ->
        assert url == "https://openidconnect.googleapis.com/v1/userinfo"
        assert {"authorization", "Bearer " <> "FAKE" <> "_GTOKEN"} in headers
        {:ok, %{status: 200, body: %{"email" => "dmh@example.com"}}}
      end)

      assert {:ok, %{email: "dmh@example.com"}} =
               GoogleWorkspace.fetch_userinfo("FAKE" <> "_GTOKEN")
    end

    test "M365 extracts the email from Graph's OIDC userinfo" do
      Application.put_env(:dmh_ai, :__oidc_userinfo_stub__, fn url, _ ->
        assert url == "https://graph.microsoft.com/oidc/userinfo"
        {:ok, %{status: 200, body: %{"email" => "ops@contoso.com"}}}
      end)

      assert {:ok, %{email: "ops@contoso.com"}} =
               M365.fetch_userinfo("FAKE" <> "_MTOKEN")
    end

    test "Calendly walks the nested resource.email path" do
      Application.put_env(:dmh_ai, :__oidc_userinfo_stub__, fn url, _ ->
        assert url == "https://api.calendly.com/users/me"
        {:ok, %{status: 200, body: %{"resource" => %{"email" => "sched@example.com"}}}}
      end)

      assert {:ok, %{email: "sched@example.com"}} =
               Calendly.fetch_userinfo("FAKE" <> "_CTOKEN")
    end
  end

  describe "OAuthIdentity.implements?" do
    test "true for connectors that opt into the callback" do
      assert OAuthIdentity.implements?(HubSpot)
      assert OAuthIdentity.implements?(GoogleWorkspace)
      assert OAuthIdentity.implements?(M365)
      assert OAuthIdentity.implements?(Calendly)
    end

    test "false for Stripe (no OAuth, no userinfo)" do
      refute OAuthIdentity.implements?(DmhAi.Connectors.Stripe)
    end

    test "false for unknown modules" do
      refute OAuthIdentity.implements?(:does_not_exist)
      refute OAuthIdentity.implements?(nil)
    end
  end
end
