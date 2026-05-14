# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R09.
#
# Phase 0.1 added org scoping. Org boundaries are enforced at the BE
# application layer — `Permissions.can?/3`, KB queries, audit log —
# NOT at the kernel / filesystem layer inside the sandbox. The
# sandbox only ever sees `email + uid`; it has no notion of org_id.
# This is the deliberate split: the FS fence is per-uid (one user =
# one workspace tree, mode 0700), and org membership is a separate
# concern computed in Elixir.
#
# R09 pins that contract: two users in the SAME custom org still
# get distinct uids and still cannot read each other's workspaces.
# An "org membership relaxes the workspace fence" regression would
# leak any team-mate's working files via a single `cat`.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R09WorkspaceFenceOrgBlind do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Tools.RunScript
  alias DmhAi.Permissions.SandboxUser
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  test "two users in the same custom org still get distinct uids; per-uid fence holds across org-mates" do
    rand   = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    org_id = "org_shared_#{rand}"

    now = System.system_time(:millisecond)
    query!(Repo,
      "INSERT INTO organizations (id, name, created_at) VALUES (?, ?, ?)",
      [org_id, "Shared Org #{rand}", now])

    {alice_id, alice_email, alice_session} = mint_user(org_id, "alice")
    {bob_id,   bob_email,   bob_session}   = mint_user(org_id, "bob")

    {:ok, uid_a} = SandboxUser.ensure_provisioned(%{id: alice_id, email: alice_email})
    {:ok, uid_b} = SandboxUser.ensure_provisioned(%{id: bob_id,   email: bob_email})

    refute uid_a == uid_b,
           "two distinct users in one org must get two distinct uids — uid allocation must be per-user, not per-org"
    assert uid_a >= 10001 and uid_b >= 10001,
           "non-admin uids must be ≥ 10001 (10000 is the master service identity)"

    a_workspace = Constants.session_workspace_dir(alice_email, alice_session)
    File.mkdir_p!(a_workspace)
    secret_path = Path.join(a_workspace, "team_secret.txt")
    File.write!(secret_path, "ORG-MATE-PRIVATE-#{rand}")
    {_, 0} = System.cmd("chown", ["-R", "#{uid_a}:#{uid_a}", a_workspace])

    ctx_b = %{
      user_id:    bob_id,
      user_email: bob_email,
      user_role:  "user",
      session_id: bob_session
    }

    File.mkdir_p!(Constants.session_workspace_dir(bob_email, bob_session))

    script = "cat #{secret_path} 2>&1; echo EXIT=$?"
    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx_b)

    refute String.contains?(to_string(output), "ORG-MATE-PRIVATE-#{rand}"),
           """
           Org-mate fence breach: Bob (uid #{uid_b}, same org as Alice)
           read Alice's workspace file via `cat`. The 0700 fence on
           `/data/user_workspaces/<email>/` must hold regardless of
           org membership — org boundaries are enforced ONLY at the
           BE app layer, never at the kernel/FS layer. A "members
           of one org can see each other's working files"
           relaxation would leak every team-mate's in-progress
           output through `cat`.
           """

    assert String.contains?(to_string(output), "Permission denied") or
           String.contains?(to_string(output), "EXIT=1") or
           String.contains?(to_string(output), "EXIT=2"),
           "expected EACCES (Permission denied) from kernel; got: #{inspect(output)}"
  end

  defp mint_user(org_id, label) do
    rand    = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    user_id = "u_#{label}_#{rand}"
    email   = "#{label}_#{rand}@dmhai.test"
    session = "S_#{label}_#{rand}"
    now     = System.system_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "FAKE-HASH-FOR-TEST-ONLY", "user", org_id, "member", now])

    {user_id, email, session}
  end
end
