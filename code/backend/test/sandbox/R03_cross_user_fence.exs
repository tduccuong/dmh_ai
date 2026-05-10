# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R03.
#
# The per-user 0700 fence on `/data/user_workspaces/<email>/`
# (and on `/data/user_assets/<email>/`) is what makes this a
# multi-tenant-safe sandbox: user B's `cat
# /data/user_workspaces/<A>/<session>/secret` MUST fail with
# "Permission denied" because B's uid can't traverse A's
# email-level dir.
#
# Without this fence, any model invocation could exfiltrate
# another user's session output via a single `cat` — a class-of-
# bug catastrophe. R03 wedges a probe between two real per-uid
# accounts and asserts the kernel rejects it.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R03CrossUserFence do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Tools.RunScript
  alias DmhAi.Permissions.SandboxUser
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  test "user B cannot read user A's session workspace via the per-user 0700 fence" do
    rand_a = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    rand_b = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    user_a = %{
      id:    "u_a_#{rand_a}",
      email: "alice_#{rand_a}@dmhai.test",
      role:  "user",
      session_id: "Sa#{rand_a}"
    }

    user_b = %{
      id:    "u_b_#{rand_b}",
      email: "bob_#{rand_b}@dmhai.test",
      role:  "user",
      session_id: "Sb#{rand_b}"
    }

    # Insert both as real DB rows so ensure_provisioned/1 can
    # allocate sequential UIDs (≥ 10001 each).
    insert_user(user_a)
    insert_user(user_b)

    # Provision A — allocates uid_a, chowns A's workspace tree
    # to uid_a, mode 0700.
    {:ok, uid_a} = SandboxUser.ensure_provisioned(%{id: user_a.id, email: user_a.email})
    assert uid_a >= 10001, "non-admin uid must be ≥ 10001 (10000 reserved for master)"

    # Stage A's secret. Master (root in container) writes it,
    # then chowns to uid_a so a sandbox process running as uid_a
    # can read its own file.
    a_workspace = Constants.session_workspace_dir(user_a.email, user_a.session_id)
    File.mkdir_p!(a_workspace)
    secret_path = Path.join(a_workspace, "alice_secret.txt")
    File.write!(secret_path, "ALICE-PRIVATE-CONTENT")
    {_, 0} = System.cmd("chown", ["-R", "#{uid_a}:#{uid_a}", a_workspace])

    # Provision B — different uid, different workspace branch.
    {:ok, uid_b} = SandboxUser.ensure_provisioned(%{id: user_b.id, email: user_b.email})
    assert uid_b != uid_a, "two distinct non-admin users must get distinct uids"

    # B's run_script tries to read A's secret. The 0700 fence on
    # A's email dir means B's uid can't even traverse it; `cat`
    # gets EACCES well before reaching the file.
    ctx_b = Map.put(user_b, :user_role, "user")
            |> Map.put(:user_id, user_b.id)
            |> Map.put(:user_email, user_b.email)

    script = "cat #{secret_path} 2>&1; echo EXIT=$?"

    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx_b)

    refute String.contains?(to_string(output), "ALICE-PRIVATE-CONTENT"),
           """
           cross-user fence breach: user B (uid #{uid_b}) read user A's
           (uid #{uid_a}) workspace file. The 0700 fence on
           /data/user_workspaces/<email>/ is the load-bearing security
           boundary for multi-tenant deployments — if it failed here,
           it failed in production.
           """

    # The kernel surfaces it as Permission denied on a path component.
    assert String.contains?(to_string(output), "Permission denied") or
           String.contains?(to_string(output), "EXIT=1") or
           String.contains?(to_string(output), "EXIT=2"),
           "expected EACCES from kernel; got: #{inspect(output)}"
  end

  defp insert_user(%{id: id, email: email, role: role}) do
    now = System.system_time(:millisecond)

    query!(Repo, """
    INSERT INTO users (id, email, password_hash, role, created_at)
    VALUES (?, ?, ?, ?, ?)
    """, [id, email, "FAKE-HASH-FOR-TEST-ONLY", role, now])
  end
end
