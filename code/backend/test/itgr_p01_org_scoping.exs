# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P01OrgScopingTest do
  @moduledoc """
  Acceptance tests for Primitive 0.1 — org / tenant scoping.

  Invariants verified:

    * Fresh install has the default org seeded (`organizations.id =
      "default"`).
    * Every user has a non-NULL `org_id` and `org_role`.
    * KB rows always carry `org_id`; memo rows always carry both
      `org_id` and `user_id`.
    * `Permissions.can?/3` enforces the role matrix and writes
      `audit_log` rows on denial.
    * `AgentSettings.for_org/3` reads an org override layered over
      install-wide settings.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Permissions
  alias DmhAi.Agent.AgentSettings
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org DmhAi.Constants.default_org_id()

  setup do
    # Test runs against a real install (the Mix test env shares the
    # production DB). We don't truncate org-scoped tables — these
    # tests probe invariants without mutating beyond their own rows.
    :ok
  end

  describe "fresh install" do
    test "default org seeded" do
      %{rows: rows} = query!(Repo, "SELECT id, name FROM organizations WHERE id=?", [@default_org])
      assert [[@default_org, _name]] = rows
    end

    test "every user has org_id + org_role set" do
      %{rows: rows} =
        query!(Repo, "SELECT COUNT(*) FROM users WHERE org_id IS NULL OR org_role IS NULL", [])

      [[count]] = rows
      assert count == 0, "found #{count} user rows with NULL org_id or org_role"
    end

    test "admin user lands in the default org with org_role='admin'" do
      %{rows: rows} =
        query!(Repo, "SELECT org_id, org_role FROM users WHERE email=?", ["admin@dmhai.local"])

      assert [[@default_org, "admin"]] = rows
    end
  end

  describe "KB / memo schema invariants" do
    test "kb_sources has no rows with NULL org_id" do
      [[count]] = query!(Repo, "SELECT COUNT(*) FROM kb_sources WHERE org_id IS NULL", []).rows
      assert count == 0
    end

    test "memo_sources rows always have both org_id and user_id" do
      [[count]] =
        query!(
          Repo,
          "SELECT COUNT(*) FROM memo_sources WHERE org_id IS NULL OR user_id IS NULL",
          []
        ).rows

      assert count == 0
    end

    test "kb_sources no longer carries a 'scope' or 'user_id' column" do
      %{columns: cols} = query!(Repo, "SELECT * FROM kb_sources LIMIT 0", [])
      refute "scope" in cols, "kb_sources should not have a `scope` column"
      refute "user_id" in cols, "kb_sources should not have a `user_id` column"
    end
  end

  describe "Permissions.can?/3" do
    setup do
      now = System.os_time(:second)
      uid = "test_user_" <> T.uid()

      query!(
        Repo,
        """
        INSERT INTO users (id, email, name, password_hash, role,
                           org_id, org_role, created_at)
        VALUES (?, ?, NULL, 'x', 'user', ?, ?, ?)
        """,
        [uid, "#{uid}@test.local", @default_org, "member", now]
      )

      on_exit(fn ->
        query!(Repo, "DELETE FROM users WHERE id=?", [uid])
        query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [uid])
      end)

      {:ok, %{user_id: uid}}
    end

    test "member can :read_kb but not :write_settings", %{user_id: uid} do
      assert Permissions.can?(uid, :read_kb, "kb:*")
      refute Permissions.can?(uid, :write_settings, "org_settings")
    end

    test "member denial writes an audit_log row with reason", %{user_id: uid} do
      refute Permissions.can?(uid, :write_settings, "org_settings")

      [[reason, outcome]] =
        query!(
          Repo,
          "SELECT reason, outcome FROM audit_log WHERE user_id=? ORDER BY id DESC LIMIT 1",
          [uid]
        ).rows

      assert outcome == "denied"
      assert reason == "role_too_low"
    end

    test "member acting on their own creds is allowed (self-pass)", %{user_id: uid} do
      assert Permissions.can?(uid, :act_as_creds, "creds:google_workspace:#{uid}")
    end

    test "member acting on another user's creds is denied", %{user_id: uid} do
      # Seed a peer user in the same org.
      peer = "peer_user_" <> T.uid()

      query!(
        Repo,
        """
        INSERT INTO users (id, email, name, password_hash, role,
                           org_id, org_role, created_at)
        VALUES (?, ?, NULL, 'x', 'user', ?, ?, ?)
        """,
        [peer, "#{peer}@test.local", @default_org, "member", System.os_time(:second)]
      )

      on_exit(fn -> query!(Repo, "DELETE FROM users WHERE id=?", [peer]) end)

      refute Permissions.can?(uid, :act_as_creds, "creds:google_workspace:#{peer}")

      denial = Permissions.denial(uid, :act_as_creds, "creds:google_workspace:#{peer}")
      assert denial.reason == :not_admin
      assert is_list(denial.remediation)
      assert length(denial.remediation) > 0
    end

    test "admin acting on another same-org user's creds is allowed", %{user_id: uid} do
      [[admin_uid, _]] =
        query!(Repo, "SELECT id, role FROM users WHERE email=?", ["admin@dmhai.local"]).rows

      # The admin's install-level role is "admin" — every check passes
      # via the install-admin bypass, including cross-user creds.
      assert Permissions.can?(admin_uid, :act_as_creds, "creds:google_workspace:#{uid}")
    end

    test "install-level admin bypass" do
      [[admin_uid]] =
        query!(Repo, "SELECT id FROM users WHERE email=?", ["admin@dmhai.local"]).rows

      assert Permissions.can?(admin_uid, :write_settings, "org_settings")
      assert Permissions.can?(admin_uid, :write_kb, "kb:*")
      assert Permissions.can?(admin_uid, :request_approval, "user:#{admin_uid}")
      assert Permissions.can?(admin_uid, :administer, "org_settings")
    end

    test "parse_target splits the tagged forms" do
      assert Permissions.parse_target("user:u_abc") ==
               %{tag: :user, user_id: "u_abc"}

      assert Permissions.parse_target("creds:google_workspace:u_abc") ==
               %{tag: :creds, slug: "google_workspace", user_id: "u_abc"}

      assert Permissions.parse_target("kb:src_42") ==
               %{tag: :kb, source_id: "src_42"}

      assert Permissions.parse_target("org_settings") ==
               %{tag: :org_settings}
    end

    test "unknown action atom raises", %{user_id: uid} do
      assert_raise ArgumentError, ~r/unknown action/, fn ->
        Permissions.can?(uid, :not_a_real_action, "user:#{uid}")
      end
    end
  end

  describe "AgentSettings.for_org/3" do
    test "missing org override falls back to install-wide / default" do
      assert AgentSettings.for_org(nil, "nope_no_such_key", "fallback") == "fallback"
      assert AgentSettings.for_org(@default_org, "nope_no_such_key", "fallback") == "fallback"
    end

    test "org override beats install-wide" do
      org_id = "test_org_" <> T.uid()
      install_wide = %{"someKey" => "install_value"}
      org_override = %{"someKey" => "org_value"}

      # Seed install-wide settings.
      query!(
        Repo,
        "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
        ["admin_cloud_settings", Jason.encode!(install_wide)]
      )

      query!(
        Repo,
        "INSERT INTO organizations (id, name, settings_json, created_at) VALUES (?, ?, ?, ?)",
        [org_id, "Test Org", Jason.encode!(org_override), System.os_time(:millisecond)]
      )

      try do
        assert AgentSettings.for_org(nil, "someKey", "missing") == "install_value"
        assert AgentSettings.for_org(org_id, "someKey", "missing") == "org_value"
      after
        query!(Repo, "DELETE FROM organizations WHERE id=?", [org_id])
        query!(Repo, "DELETE FROM settings WHERE key=?", ["admin_cloud_settings"])
      end
    end
  end

  describe "DmhAi.Orgs.for_user/1" do
    test "returns user's org_id when set" do
      [[admin_uid, admin_org]] =
        query!(Repo, "SELECT id, org_id FROM users WHERE email=?", ["admin@dmhai.local"]).rows

      assert DmhAi.Orgs.for_user(admin_uid) == admin_org
    end

    test "returns default org when user not found" do
      assert DmhAi.Orgs.for_user("does_not_exist") == @default_org
    end

    test "returns default org for nil" do
      assert DmhAi.Orgs.for_user(nil) == @default_org
    end
  end
end
