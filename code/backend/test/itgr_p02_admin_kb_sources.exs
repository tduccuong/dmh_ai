# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P02AdminKbSourcesTest do
  @moduledoc """
  G3 — pin the contract of the two admin KB-source endpoints that
  the demo/02_kb_*.md runbooks rely on:

      GET  /admin/kb-sources           → 200 { sources: [...] }, org-scoped
      POST /admin/kb-sources/remove    → 200 { ok: true, source_id }, writes history row

  Both routes go through `Permissions.can?(uid, :write_settings, "org_settings")`;
  non-admin callers get 403 with no side effect.

  Tests use the Router end-to-end (Plug.Test conn → Router.call) so the
  AuthPlug + Permissions gate are exercised, not just the handler in
  isolation.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org DmhAi.Constants.default_org_id()

  setup do
    admin_id    = T.uid()
    nonadmin_id = T.uid()
    admin_email    = "admin-#{admin_id}@test.local"     |> String.downcase()
    nonadmin_email = "user-#{nonadmin_id}@test.local"   |> String.downcase()
    password = "pw-#{admin_id}"

    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, admin_email, "Admin", "user",
       DmhAi.AuthPlug.hash_password(password), 1,
       @default_org, "admin", now])

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [nonadmin_id, nonadmin_email, "User", "user",
       DmhAi.AuthPlug.hash_password(password), 1,
       @default_org, "member", now])

    # Seed two kb_sources rows for the default org and one for a
    # sibling org, so we can assert org scoping in the list response.
    other_org = "org_sibling_#{admin_id}"
    query!(Repo,
      "INSERT INTO organizations (id, name, created_at) VALUES (?, ?, ?)",
      [other_org, "Sibling Org", now])

    sid_a = "src_a_#{admin_id}"
    sid_b = "src_b_#{admin_id}"
    sid_x = "src_x_other_org_#{admin_id}"

    insert_kb_source(@default_org, sid_a, "url",  "Doc A", now)
    insert_kb_source(@default_org, sid_b, "file", "Doc B", now)
    insert_kb_source(other_org,    sid_x, "url",  "Sibling Doc",  now)

    on_exit(fn ->
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id IN (?, ?)", [admin_id, nonadmin_id])
      query!(Repo, "DELETE FROM kb_source_history WHERE org_id IN (?, ?)", [@default_org, other_org])
      query!(Repo, "DELETE FROM kb_sources WHERE source_id IN (?, ?, ?)", [sid_a, sid_b, sid_x])
      query!(Repo, "DELETE FROM organizations WHERE id=?", [other_org])
      query!(Repo, "DELETE FROM users WHERE id IN (?, ?)", [admin_id, nonadmin_id])
    end)

    %{admin_email: admin_email,
      nonadmin_email: nonadmin_email,
      password: password,
      admin_id: admin_id,
      sid_a: sid_a, sid_b: sid_b, sid_x: sid_x,
      other_org: other_org}
  end

  describe "GET /admin/kb-sources" do
    test "admin sees ONLY their org's sources", %{admin_email: e, password: p,
                                                  sid_a: sid_a, sid_b: sid_b, sid_x: sid_x} do
      token = login(e, p)
      conn  = get_json("/admin/kb-sources", token: token)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["sources"])

      ids = Enum.map(body["sources"], & &1["source_id"])
      assert sid_a in ids
      assert sid_b in ids
      refute sid_x in ids, "list MUST be org-scoped — sibling org's source leaked through"
    end

    test "response shape includes the documented fields", %{admin_email: e, password: p,
                                                            sid_a: sid_a} do
      token = login(e, p)
      conn  = get_json("/admin/kb-sources", token: token)

      assert conn.status == 200
      [row] =
        Jason.decode!(conn.resp_body)["sources"]
        |> Enum.filter(&(&1["source_id"] == sid_a))

      for key <- ~w(source_id source_kind title content_sha256
                    last_indexed_at last_seen_at ingest_status) do
        assert Map.has_key?(row, key), "response is missing documented field #{key}"
      end
    end

    test "non-admin gets 403", %{nonadmin_email: e, password: p} do
      token = login(e, p)
      conn  = get_json("/admin/kb-sources", token: token)
      assert conn.status == 403
    end

    test "unauthenticated gets 401", %{} do
      conn = get_json("/admin/kb-sources")
      assert conn.status == 401
    end
  end

  describe "POST /admin/kb-sources/remove" do
    test "admin remove valid source_id → 200, source gone, history row written",
         %{admin_email: e, password: p, admin_id: admin_id, sid_a: sid_a} do
      token = login(e, p)
      conn  = post_json("/admin/kb-sources/remove",
                        %{"source_id" => sid_a, "reason" => "outdated"},
                        token: token)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"ok" => true, "source_id" => sid_a}

      [[count]] =
        query!(Repo, "SELECT COUNT(*) FROM kb_sources WHERE org_id=? AND source_id=?",
               [@default_org, sid_a]).rows
      assert count == 0

      [[history_count, reason, removed_by]] =
        query!(Repo,
               "SELECT COUNT(*), MAX(reason), MAX(removed_by_user_id) FROM kb_source_history " <>
                 "WHERE org_id=? AND source_id=?",
               [@default_org, sid_a]).rows

      assert history_count == 1, "history row must be written exactly once"
      assert reason == "outdated"
      assert removed_by == admin_id
    end

    test "missing source_id → 400", %{admin_email: e, password: p} do
      token = login(e, p)
      conn  = post_json("/admin/kb-sources/remove", %{}, token: token)
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "missing source_id"
    end

    test "non-admin → 403, no side effect", %{nonadmin_email: e, password: p,
                                               sid_b: sid_b} do
      token = login(e, p)
      conn  = post_json("/admin/kb-sources/remove",
                        %{"source_id" => sid_b}, token: token)
      assert conn.status == 403

      [[count]] =
        query!(Repo, "SELECT COUNT(*) FROM kb_sources WHERE org_id=? AND source_id=?",
               [@default_org, sid_b]).rows
      assert count == 1, "non-admin removal MUST NOT delete the source"
    end

    test "unauthenticated → 401", %{sid_b: sid_b} do
      conn = post_json("/admin/kb-sources/remove", %{"source_id" => sid_b})
      assert conn.status == 401
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp insert_kb_source(org_id, source_id, kind, title, ts) do
    query!(Repo,
      "INSERT INTO kb_sources (org_id, source_id, source_kind, title, content_sha256, " <>
        "last_indexed_at, last_seen_at, ingest_status, indexed_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [org_id, source_id, kind, title,
       :crypto.hash(:sha256, source_id) |> Base.encode16(case: :lower),
       ts, ts, "indexed", ts])
  end

  defp random_ip, do: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(254)}

  defp get_json(path, opts \\ []) do
    conn =
      Plug.Test.conn(:get, path, "")
      |> Map.put(:remote_ip, random_ip())

    conn =
      case Keyword.get(opts, :token) do
        nil -> conn
        tok -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> tok)
      end

    DmhAi.Router.call(conn, DmhAi.Router.init([]))
  end

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
