# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R15.
#
# The sandbox container can restart (operator action, OOM, host
# reboot). `/etc/passwd` is ephemeral — every per-user OS account
# `useradd`'d by `SandboxUser.ensure_os_user/1` disappears on restart.
# The DB is the persistent source of truth for `users.unix_uid`, so
# the contract is: after a restart, the next `ensure_provisioned/1`
# call for a user lazily re-creates the OS account AT THE SAME UID.
#
# Restarting the test container mid-suite is invasive (drops iptables
# state, breaks every other test running concurrently). R15
# simulates the post-restart state by directly deleting the OS
# account via `userdel` inside the live sandbox. That triggers the
# exact same code path `ensure_os_user/1`'s `id` precheck takes when
# the user is missing — without the cost or fragility of a real
# container restart.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R15ReprovisionAfterAccountLoss do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Permissions.SandboxUser
  alias DmhAi.Agent.Sandbox
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @docker_timeout_ms 5_000

  test "ensure_provisioned re-creates the OS user at the SAME uid after `/etc/passwd` loses the entry" do
    rand    = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    user_id = "u_reprov_#{rand}"
    email   = "reprov_#{rand}@dmhai.test"
    now     = System.system_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "FAKE-HASH-FOR-TEST-ONLY", "user",
       DmhAi.Constants.default_org_id(), "member", now])

    {:ok, first_uid} = SandboxUser.ensure_provisioned(%{id: user_id, email: email})
    assert first_uid >= 10001
    assert_account_exists!(first_uid, "first provisioning didn't create the OS account")

    # Persist what the DB recorded for unix_uid — this is the value
    # that must survive an account-loss / restart cycle.
    [[db_uid]] =
      query!(Repo, "SELECT unix_uid FROM users WHERE id=?", [user_id]).rows

    assert db_uid == first_uid,
           "DB persisted #{db_uid}, ensure_provisioned returned #{first_uid}"

    # Simulate post-restart state — wipe the OS account. `userdel` is
    # part of the shadow package installed in the sandbox Dockerfile.
    delete_os_user(first_uid)
    refute account_exists?(first_uid),
           "userdel didn't actually drop the account — test fixture broken"

    # Re-provision. The DB still has unix_uid=#{first_uid}, so
    # `ensure_provisioned` must reuse it and re-`useradd` the
    # corresponding OS account.
    {:ok, second_uid} = SandboxUser.ensure_provisioned(%{id: user_id, email: email})

    assert second_uid == first_uid,
           """
           Re-provisioning returned uid #{second_uid}, but the
           original was #{first_uid}. Every persistent uid-keyed
           resource (workspace dir ownership, iptables uid-owner
           ACCEPTs in admin's case) assumes a user keeps the same
           uid for the lifetime of the install. A bumped uid here
           would orphan every file under
           `/data/user_workspaces/<email>/`.
           """

    assert_account_exists!(second_uid, "OS account was NOT re-created after the simulated restart")
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp account_exists?(uid) do
    case SandboxUser.docker(
           ["exec", Sandbox.container_name(), "id", SandboxUser.username_for(uid)],
           @docker_timeout_ms
         ) do
      {:ok, _, 0} -> true
      _ -> false
    end
  end

  defp assert_account_exists!(uid, ctx_msg) do
    assert account_exists?(uid),
           "#{ctx_msg} — OS account `#{SandboxUser.username_for(uid)}` (uid #{uid}) missing in /etc/passwd"
  end

  defp delete_os_user(uid) do
    SandboxUser.docker(
      ["exec", Sandbox.container_name(), "userdel", SandboxUser.username_for(uid)],
      @docker_timeout_ms
    )
  end
end
