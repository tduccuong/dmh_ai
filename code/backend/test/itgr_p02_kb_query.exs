# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P02KbQueryTest do
  @moduledoc """
  G4 — pin the contract of `POST /kb/query`.

  This endpoint is the public KB query surface (partial 0.6 — REST
  API). Unlike the admin KB endpoints (`/admin/kb-sources/*`) it's
  callable by ANY authenticated user; org-scoping is automatic via
  `Orgs.for_user/1`. The agent's internal `fetch_index` tool and
  this endpoint hit the same `VectorDB.search` codepath.

  Without these tests a regression that drops org scoping or
  changes the response shape lands silently — the F-tier covers
  the chat path only, not the HTTP endpoint shape.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Ingest, Repo}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org DmhAi.Constants.default_org_id()
  @embedding_dim 1024

  setup_all do
    Application.put_env(:dmh_ai, :__embedder_stub__, fn texts ->
      vecs =
        Enum.map(texts, fn text ->
          seed = :crypto.hash(:sha256, text)
          bytes = :binary.copy(seed, div(@embedding_dim, byte_size(seed)) + 1)
          for(<<b <- bytes>>, do: b / 255.0) |> Enum.take(@embedding_dim)
        end)

      {:ok, vecs}
    end)

    Application.put_env(:dmh_ai, :__tagger_stub__, fn _body -> [] end)

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__embedder_stub__)
      Application.delete_env(:dmh_ai, :__tagger_stub__)
    end)

    :ok
  end

  setup do
    user_id     = T.uid()
    nonadmin_id = T.uid()
    other_org_user_id = T.uid()

    user_email     = "kb-user-#{user_id}@test.local"     |> String.downcase()
    nonadmin_email = "kb-na-#{nonadmin_id}@test.local"   |> String.downcase()
    other_email    = "kb-other-#{other_org_user_id}@test.local" |> String.downcase()
    password = "pw-#{user_id}"

    now = System.os_time(:millisecond)

    # Default-org admin (used to ingest into the default org's KB).
    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, user_email, "Admin", "user",
       DmhAi.AuthPlug.hash_password(password), 1,
       @default_org, "admin", now])

    # Non-admin in same org — must be ALLOWED to call /kb/query.
    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [nonadmin_id, nonadmin_email, "Member", "user",
       DmhAi.AuthPlug.hash_password(password), 1,
       @default_org, "member", now])

    # Different-org admin — must NOT see the default-org KB hits.
    other_org = "org_other_kbq_#{user_id}"
    query!(Repo,
      "INSERT INTO organizations (id, name, created_at) VALUES (?, ?, ?)",
      [other_org, "Other Org", now])

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [other_org_user_id, other_email, "Other Admin", "user",
       DmhAi.AuthPlug.hash_password(password), 1,
       other_org, "admin", now])

    # Seed one source per org so we can assert org scoping.
    body_default = "Default-org canonical document: parental leave policy " <>
                     "extends to all permanent employees regardless of role."

    body_other   = "Other-org canonical document: travel reimbursement policy " <>
                     "follows the parent company's per-diem schedule strictly."

    {:ok, _} = Ingest.upsert_kb_source(
      %{scope: :knowledge, org_id: @default_org, source_kind: "text",
        source_ref: "test://kbq/default-#{user_id}", title: "Default Org Doc"},
      body_default)

    {:ok, _} = Ingest.upsert_kb_source(
      %{scope: :knowledge, org_id: other_org, source_kind: "text",
        source_ref: "test://kbq/other-#{user_id}", title: "Other Org Doc"},
      body_other)

    on_exit(fn ->
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id IN (?, ?, ?)",
             [user_id, nonadmin_id, other_org_user_id])

      query!(Repo,
        "DELETE FROM kb_chunks_meta WHERE source_id IN " <>
          "(SELECT id FROM kb_sources WHERE source_id LIKE 'test://kbq/%')", [])

      query!(Repo, "DELETE FROM kb_sources WHERE source_id LIKE 'test://kbq/%'", [])
      query!(Repo, "DELETE FROM users WHERE id IN (?, ?, ?)",
             [user_id, nonadmin_id, other_org_user_id])
      query!(Repo, "DELETE FROM organizations WHERE id=?", [other_org])
    end)

    %{user_email: user_email,
      nonadmin_email: nonadmin_email,
      other_email: other_email,
      password: password,
      other_org: other_org}
  end

  describe "POST /kb/query" do
    test "admin in default org gets hits with documented shape",
         %{user_email: e, password: p} do
      token = login(e, p)
      conn  = post_json("/kb/query", %{"q" => "parental leave policy"}, token: token)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["hits"])
      assert length(body["hits"]) >= 1

      hit = hd(body["hits"])

      for key <- ~w(source source_kind source_id text score) do
        assert Map.has_key?(hit, key),
               "response hit missing documented field #{key}: #{inspect(hit)}"
      end

      assert is_binary(hit["text"])
      assert is_number(hit["score"])
    end

    test "non-admin in same org IS ALLOWED (public KB query)",
         %{nonadmin_email: e, password: p} do
      token = login(e, p)
      conn  = post_json("/kb/query", %{"q" => "parental leave policy"}, token: token)

      assert conn.status == 200,
             "non-admin must be allowed to query the org KB — this endpoint is the " <>
               "public read surface, not an admin endpoint"

      body = Jason.decode!(conn.resp_body)
      assert is_list(body["hits"])
    end

    test "cross-org caller sees ZERO hits from the default-org KB",
         %{other_email: e, password: p} do
      token = login(e, p)
      conn  = post_json("/kb/query", %{"q" => "parental leave policy"}, token: token)

      assert conn.status == 200
      hits = Jason.decode!(conn.resp_body)["hits"]

      refute Enum.any?(hits, fn h ->
               String.contains?(h["text"] || "", "Default-org canonical")
             end),
             "cross-org isolation breach: other-org user retrieved default-org KB content"
    end

    test "missing q → 400", %{user_email: e, password: p} do
      token = login(e, p)
      conn  = post_json("/kb/query", %{}, token: token)
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "missing q"
    end

    test "empty q → 400 (treated as missing)", %{user_email: e, password: p} do
      token = login(e, p)
      conn  = post_json("/kb/query", %{"q" => ""}, token: token)
      assert conn.status == 400
    end

    test "unauthenticated → 401", %{} do
      conn = post_json("/kb/query", %{"q" => "anything"})
      assert conn.status == 401
    end

    test "respects optional limit", %{user_email: e, password: p} do
      token = login(e, p)
      conn  = post_json("/kb/query", %{"q" => "parental leave policy", "limit" => 1},
                        token: token)

      assert conn.status == 200
      hits = Jason.decode!(conn.resp_body)["hits"]
      assert length(hits) <= 1
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp random_ip, do: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(254)}

  defp post_json(path, body, opts \\ []) do
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:post, path, json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, random_ip())

    conn =
      case Keyword.get(opts, :token) do
        nil -> conn
        tok -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> tok)
      end

    DmhAi.Router.call(conn, DmhAi.Router.init([]))
  end

  defp login(email, password) do
    conn = post_json("/auth/login", %{"email" => email, "password" => password})
    assert conn.status == 200, "login failed: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)["token"]
  end
end
