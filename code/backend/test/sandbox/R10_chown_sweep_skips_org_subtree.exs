# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R10.
#
# Phase 0.1 introduced `/data/user_assets/_org/<org_id>/` — a shared
# subtree for org-wide uploaded assets that EVERY member of the org
# can read. Ownership policy for that subtree differs from the per-
# user subtree: it's owned by root (mode 0755) so any sandbox uid can
# traverse and read it; per-user `<email>/` subtrees are 0700 per-uid.
#
# The chown sweep (`SandboxUser.ensure_sandbox_assets_perms/2`,
# fired during `ensure_provisioned/1`) walks
# `/data/user_assets/<email>/` and chowns recursively to the
# corresponding uid. The sweep MUST NOT touch the sibling
# `_org/<id>/` subtree — if it did, the next user's provisioning
# would clobber the org subtree's ownership and leave it readable
# only by that one user, breaking org-wide sharing.
#
# R10 pins the boundary: stage a file under `_org/<id>/` owned by
# root, provision a user, verify the org file's owner is unchanged.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R10ChownSweepSkipsOrgSubtree do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Permissions.SandboxUser
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  test "ensure_provisioned/1 does NOT chown the _org/<id>/ subtree" do
    rand   = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    org_id = "org_kb_#{rand}"

    org_subtree = Path.join([Constants.assets_dir(), "_org", org_id])
    File.mkdir_p!(org_subtree)
    org_file = Path.join(org_subtree, "team_doc.bin")
    File.write!(org_file, "ORG-SHARED-#{rand}")
    {_, 0} = System.cmd("chown", ["-R", "0:0", Path.join(Constants.assets_dir(), "_org")])
    {_, 0} = System.cmd("chmod", ["0755", org_subtree])

    %{uid: pre_uid} = File.stat!(org_file)
    assert pre_uid == 0, "test fixture: org file must start root-owned"

    user_id = "u_#{rand}"
    email   = "user_#{rand}@dmhai.test"
    now     = System.system_time(:millisecond)

    query!(Repo,
      "INSERT INTO organizations (id, name, created_at) VALUES (?, ?, ?)",
      [org_id, "KB Org #{rand}", now])

    query!(Repo,
      "INSERT INTO users (id, email, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "FAKE-HASH-FOR-TEST-ONLY", "user", org_id, "member", now])

    {:ok, uid} = SandboxUser.ensure_provisioned(%{id: user_id, email: email})
    assert uid >= 10001

    %{uid: post_uid} = File.stat!(org_file)
    assert post_uid == 0,
           """
           Chown sweep regression: provisioning user `#{email}`
           changed `_org/#{org_id}/team_doc.bin` owner from root
           (0) to #{post_uid}. The sweep is keyed on the per-user
           `<email>/` subtree and MUST NOT recurse into the sibling
           `_org/<id>/` tree. A failure here means the next user
           provisioning would re-chown the org tree to THEIR uid,
           making it 0700 / one-user-readable and silently breaking
           org-wide KB visibility.
           """

    assert File.read!(org_file) == "ORG-SHARED-#{rand}",
           "content of the org file must be unchanged after the sweep"
  end
end
