# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P09IdentitiesTest do
  @moduledoc """
  Primitive 0.9 — Identities module integration tests.

  Coverage:

    * `Identities.resolve/2` cache hit (manual override).
    * Cache miss + connector with `identity_lookup: nil` →
      `:connector_has_no_identity_lookup`.
    * `put_manual_override/4` survives the default TTL.
    * `invalidate/2` drops one (slug) row; `invalidate_all/1`
      drops every row for a user.
    * Cross-org isolation: rows scope by `org_id`.
    * `users.email_aliases` JSON round-trips through the schema.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Identities, Repo}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org DmhAi.Constants.default_org_id()

  setup do
    now = System.os_time(:second)
    uid = "id_test_" <> T.uid()

    query!(
      Repo,
      """
      INSERT INTO users (id, email, email_aliases, name, password_hash, role,
                         org_id, org_role, created_at)
      VALUES (?, ?, ?, NULL, 'x', 'user', ?, ?, ?)
      """,
      [uid, "#{uid}@test.local", Jason.encode!(["alias1.#{uid}@test.local"]),
       @default_org, "member", now]
    )

    on_exit(fn ->
      query!(Repo, "DELETE FROM connector_identities WHERE user_id=?", [uid])
      query!(Repo, "DELETE FROM users WHERE id=?", [uid])
    end)

    {:ok, %{user_id: uid}}
  end

  describe "manual override (write + read)" do
    test "put + resolve returns the override", %{user_id: uid} do
      :ok = Identities.put_manual_override(uid, "hubspot", "owner-42", "actor-1")
      assert {:ok, "owner-42"} = Identities.resolve(uid, "hubspot")
    end

    test "put twice updates the external_id (idempotent overwrite)", %{user_id: uid} do
      :ok = Identities.put_manual_override(uid, "slack",   "U001",      "actor-1")
      :ok = Identities.put_manual_override(uid, "slack",   "U002",      "actor-1")
      assert {:ok, "U002"} = Identities.resolve(uid, "slack")
    end

    test "override has ttl_s = 0 (permanent)", %{user_id: uid} do
      :ok = Identities.put_manual_override(uid, "hubspot", "42", "actor-1")

      %{rows: [[ttl_s, via]]} =
        query!(Repo, """
        SELECT ttl_s, resolved_via FROM connector_identities
        WHERE user_id=? AND connector_slug='hubspot'
        """, [uid])

      assert ttl_s == 0
      assert via == "manual_override"
    end
  end

  describe "resolve — connector with identity_lookup: nil" do
    test "returns :connector_has_no_identity_lookup", %{user_id: uid} do
      # google_workspace declares identity_lookup as nil in v1 (no
      # Directory API function in manifest yet). Resolver must
      # surface that as a typed error, not crash.
      DmhAi.Tools.Dispatcher.register(DmhAi.Connectors.GoogleWorkspace)

      assert {:error, :connector_has_no_identity_lookup} =
               Identities.resolve(uid, "google_workspace")
    end

    test "unregistered connector returns :connector_not_found", %{user_id: uid} do
      assert {:error, :connector_not_found} =
               Identities.resolve(uid, "fake_unregistered_connector_#{T.uid()}")
    end
  end

  describe "invalidation" do
    test "invalidate/2 drops a single slug row", %{user_id: uid} do
      :ok = Identities.put_manual_override(uid, "hubspot", "42", "actor-1")
      :ok = Identities.put_manual_override(uid, "slack",   "U001", "actor-1")

      :ok = Identities.invalidate(uid, "hubspot")

      assert {:error, _} = Identities.resolve(uid, "hubspot")
      assert {:ok, "U001"} = Identities.resolve(uid, "slack")
    end

    test "invalidate_all/1 drops every slug for the user", %{user_id: uid} do
      :ok = Identities.put_manual_override(uid, "hubspot", "42", "actor-1")
      :ok = Identities.put_manual_override(uid, "slack",   "U001", "actor-1")

      :ok = Identities.invalidate_all(uid)

      assert {:error, _} = Identities.resolve(uid, "hubspot")
      assert {:error, _} = Identities.resolve(uid, "slack")
    end
  end

  describe "list_for_user/1" do
    test "returns shape with slug + external_id + via + cached_at + ttl_s", %{user_id: uid} do
      :ok = Identities.put_manual_override(uid, "hubspot", "42", "actor-1")

      [row | _] = Identities.list_for_user(uid)

      assert row.slug          == "hubspot"
      assert row.external_id   == "42"
      assert row.resolved_via  == "manual_override"
      assert is_integer(row.cached_at)
      assert row.ttl_s         == 0
    end

    test "empty list when user has no identities" do
      uid_no = "id_empty_" <> T.uid()
      query!(Repo, """
      INSERT INTO users (id, email, name, password_hash, role,
                         org_id, org_role, created_at)
      VALUES (?, ?, NULL, 'x', 'user', ?, ?, ?)
      """, [uid_no, "#{uid_no}@test.local", @default_org, "member",
            System.os_time(:second)])

      on_exit(fn -> query!(Repo, "DELETE FROM users WHERE id=?", [uid_no]) end)

      assert [] = Identities.list_for_user(uid_no)
    end
  end

  describe "cross-org isolation" do
    test "rows scope by org_id", %{user_id: uid} do
      # Seed a sibling org with a user that has the same id-shape
      # but different org. The cache rows must NOT bleed across.
      sibling_org = "org_sibling_#{T.uid()}"
      sib_uid     = "id_test_" <> T.uid()

      query!(Repo, """
      INSERT INTO organizations (id, name, created_at) VALUES (?, ?, ?)
      """, [sibling_org, "Sibling", System.os_time(:millisecond)])

      query!(Repo, """
      INSERT INTO users (id, email, name, password_hash, role,
                         org_id, org_role, created_at)
      VALUES (?, ?, NULL, 'x', 'user', ?, ?, ?)
      """, [sib_uid, "#{sib_uid}@sibling.test", sibling_org, "member",
            System.os_time(:second)])

      :ok = Identities.put_manual_override(uid,     "hubspot", "DEFAULT-42", "actor")
      :ok = Identities.put_manual_override(sib_uid, "hubspot", "SIBLING-99", "actor")

      assert {:ok, "DEFAULT-42"} = Identities.resolve(uid, "hubspot")
      assert {:ok, "SIBLING-99"} = Identities.resolve(sib_uid, "hubspot")

      on_exit(fn ->
        query!(Repo, "DELETE FROM connector_identities WHERE user_id=?", [sib_uid])
        query!(Repo, "DELETE FROM users WHERE id=?", [sib_uid])
        query!(Repo, "DELETE FROM organizations WHERE id=?", [sibling_org])
      end)
    end
  end

  describe "users.email_aliases column" do
    test "JSON aliases round-trip through the schema", %{user_id: uid} do
      %{rows: [[json]]} =
        query!(Repo, "SELECT email_aliases FROM users WHERE id=?", [uid])

      assert {:ok, ["alias1." <> _]} = Jason.decode(json)
    end

    test "NULL aliases is acceptable" do
      uid_no = "id_noal_" <> T.uid()
      query!(Repo, """
      INSERT INTO users (id, email, email_aliases, name, password_hash, role,
                         org_id, org_role, created_at)
      VALUES (?, ?, NULL, NULL, 'x', 'user', ?, ?, ?)
      """, [uid_no, "#{uid_no}@test.local", @default_org, "member",
            System.os_time(:second)])

      on_exit(fn -> query!(Repo, "DELETE FROM users WHERE id=?", [uid_no]) end)

      %{rows: [[v]]} =
        query!(Repo, "SELECT email_aliases FROM users WHERE id=?", [uid_no])

      assert is_nil(v)
    end
  end

  describe "bad args" do
    test "resolve/2 with non-binary user_id returns :bad_args" do
      assert {:error, :bad_args} = Identities.resolve(nil, "hubspot")
      assert {:error, :bad_args} = Identities.resolve("uid", :hubspot)
    end
  end
end
