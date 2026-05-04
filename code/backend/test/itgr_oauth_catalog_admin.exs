# Integration tests: admin CRUD for the OAuth services catalog
# (Handlers.AdminOAuthCatalog + OAuth.Catalog write API).
#
# Coverage:
#   - GET returns list + redirect_uri; client_secret is masked
#     (replaced by has_secret boolean).
#   - POST creates a row; required fields validated.
#   - PUT updates a row; empty client_secret means "don't change".
#   - DELETE removes a row.
#   - Non-admin user gets 403 on every endpoint.
#   - extra_auth_params + extra_token_params round-trip as JSON.
#
# Run with:   MIX_ENV=test mix test test/itgr_oauth_catalog_admin.exs

defmodule Itgr.OAuthCatalogAdmin do
  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Handlers.AdminOAuthCatalog, OAuth.Catalog}
  import Ecto.Adapters.SQL, only: [query!: 3]
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  defp uid, do: T.uid()

  defp seed_user(user_id, role \\ "admin") do
    now = System.os_time(:millisecond)
    query!(Repo,
      """
      INSERT OR IGNORE INTO users (id, email, password_hash, role, created_at)
      VALUES (?,?,?,?,?)
      """,
      [user_id, "ocadm_#{user_id}@itgr.local", "", role, now])
    %{id: user_id, role: role}
  end

  defp clear_catalog do
    query!(Repo, "DELETE FROM oauth_catalog", [])
  end

  defp body_json(conn), do: Jason.decode!(conn.resp_body)

  defp call_get(user) do
    conn(:get, "/_test")
    |> AdminOAuthCatalog.list(user)
  end

  defp call_post(user, body) do
    conn(:post, "/_test", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> AdminOAuthCatalog.create(user)
  end

  defp call_put(user, id, body) do
    conn(:put, "/_test", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> AdminOAuthCatalog.update(user, to_string(id))
  end

  defp call_delete(user, id) do
    conn(:delete, "/_test")
    |> AdminOAuthCatalog.delete(user, to_string(id))
  end

  defp valid_payload(extra \\ %{}) do
    %{
      "slug"                   => "test_" <> uid(),
      "display_name"           => "Test Service",
      "host_match"             => "test.example.com",
      "authorization_endpoint" => "https://auth.test.example.com/o/auth",
      "token_endpoint"         => "https://auth.test.example.com/o/token",
      "scopes_default"         => ["read", "write"],
      "client_id"              => "client_abc",
      "client_secret"          => "shhh"
    }
    |> Map.merge(extra)
  end

  setup do
    clear_catalog()
    on_exit(fn -> clear_catalog() end)
    :ok
  end

  # ─── GET — list shape ─────────────────────────────────────────────────────

  test "GET: returns redirect_uri + services; secret masked" do
    admin = seed_user(uid())
    assert {:ok, _} = Catalog.create(valid_payload(%{"slug" => "google", "display_name" => "Google", "client_secret" => "topsecret"}))

    conn = call_get(admin)
    assert conn.status == 200
    body = body_json(conn)
    assert is_binary(body["redirect_uri"])
    assert String.ends_with?(body["redirect_uri"], "/oauth/callback")

    [svc | _] = body["services"]
    refute Map.has_key?(svc, "client_secret")
    assert svc["has_secret"] == true
  end

  # ─── POST — create ────────────────────────────────────────────────────────

  test "POST: creates a row with required fields" do
    admin = seed_user(uid())
    payload = valid_payload(%{"slug" => "newsvc", "display_name" => "New Service"})

    conn = call_post(admin, payload)
    assert conn.status == 201
    body = body_json(conn)
    assert body["slug"] == "newsvc"
    assert body["host_match"] == "test.example.com"
    assert body["has_secret"] == true
    refute Map.has_key?(body, "client_secret")
  end

  test "POST: missing required field → 400" do
    admin = seed_user(uid())
    payload = valid_payload() |> Map.delete("host_match")

    conn = call_post(admin, payload)
    assert conn.status == 400
    body = body_json(conn)
    assert body["error"] =~ "host_match"
  end

  # ─── PUT — update ─────────────────────────────────────────────────────────

  test "PUT: updates a row; empty client_secret means 'don't change'" do
    admin = seed_user(uid())
    {:ok, entry} = Catalog.create(valid_payload(%{"slug" => "edit_me", "client_secret" => "original_secret"}))

    # Update everything but leave client_secret blank — the stored
    # value should be preserved.
    payload = %{
      "display_name" => "Renamed Service",
      "scopes_default" => ["new_scope"],
      "client_secret" => ""
    }

    conn = call_put(admin, entry.id, payload)
    assert conn.status == 200
    body = body_json(conn)
    assert body["display_name"] == "Renamed Service"
    assert body["scopes_default"] == ["new_scope"]
    assert body["has_secret"] == true

    # Verify the secret is still "original_secret" via direct DB read.
    %{rows: [[secret]]} =
      query!(Repo, "SELECT client_secret FROM oauth_catalog WHERE id=?", [entry.id])
    assert secret == "original_secret"
  end

  test "PUT: explicit nil client_secret clears it" do
    admin = seed_user(uid())
    {:ok, entry} = Catalog.create(valid_payload(%{"slug" => "clear_me", "client_secret" => "original"}))

    conn = call_put(admin, entry.id, %{"client_secret" => nil})
    assert conn.status == 200
    body = body_json(conn)
    assert body["has_secret"] == false
  end

  test "PUT: unknown id → 404" do
    admin = seed_user(uid())
    conn = call_put(admin, 99_999_999, %{"display_name" => "x"})
    assert conn.status == 404
  end

  # ─── DELETE ───────────────────────────────────────────────────────────────

  test "DELETE: removes the row" do
    admin = seed_user(uid())
    {:ok, entry} = Catalog.create(valid_payload(%{"slug" => "to_delete"}))

    conn = call_delete(admin, entry.id)
    assert conn.status == 200

    assert Catalog.get_by_slug("to_delete") == nil
  end

  # ─── Auth gate ────────────────────────────────────────────────────────────

  test "non-admin gets 403 on every endpoint" do
    user = seed_user(uid(), "user")
    {:ok, entry} = Catalog.create(valid_payload(%{"slug" => "perm_test"}))

    assert call_get(user).status == 403
    assert call_post(user, valid_payload()).status == 403
    assert call_put(user, entry.id, %{"display_name" => "x"}).status == 403
    assert call_delete(user, entry.id).status == 403
  end

  # ─── Extra params round-trip ──────────────────────────────────────────────

  test "extra_auth_params + extra_token_params persist as JSON and round-trip via GET" do
    admin = seed_user(uid())

    payload = valid_payload(%{
      "slug" => "extras",
      "extra_auth_params"  => %{"access_type" => "offline", "prompt" => "consent"},
      "extra_token_params" => %{"audience" => "https://api.example.test"}
    })

    conn = call_post(admin, payload)
    assert conn.status == 201

    list_body = body_json(call_get(admin))
    [svc] = list_body["services"]
    assert svc["extra_auth_params"]  == %{"access_type" => "offline", "prompt" => "consent"}
    assert svc["extra_token_params"] == %{"audience" => "https://api.example.test"}
  end
end
