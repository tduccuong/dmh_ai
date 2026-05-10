# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R01.
#
# `RunScript.provision/1` resolves the `{username, sandbox_cwd}` pair
# the launcher passes to `docker exec`. Both shapes (admin + non-admin)
# must land the script inside the PER-SESSION workspace subdir:
#
#     /data/user_workspaces/<email>/<session_id>/
#
# A regression where the admin branch returns the workspaces ROOT
# (`/data/user_workspaces`) instead of the per-session subdir means
# every admin-authored `cp ./out.pdf …` lands one tree above where
# `/assets/<session>/<file>` knows to look — and where the per-uid
# 0700 fence prevents writes anyway. This test pins down the
# contract so a future refactor can't quietly re-introduce that
# regression.

defmodule DmhAi.Sandbox.R01ProvisionAdminCwd do
  use ExUnit.Case, async: true

  alias DmhAi.Tools.RunScript

  @moduletag :sandbox

  # `provision/1` triggers `SandboxUser.uid_for/1` (admins) /
  # `ensure_provisioned/1` (non-admins), which both call out to the
  # host filesystem (`/data/user_assets`, `/data/user_workspaces`) +
  # the sandbox container. Outside the docker harness those calls
  # `{:error, "host dir provisioning failed: …"}`. R01's job is to
  # lock the **shape** the contract returns when it succeeds, and to
  # confirm the bug shape (silent widening to workspaces ROOT) is
  # NEVER produced regardless of environment. The deeper "ownership
  # is repaired, file actually writes" check is R02's job (needs the
  # docker harness).

  test "admin success returns per-session sandbox_cwd; never widens to workspaces root" do
    ctx = %{
      user_id:    "u_admin",
      user_email: "admin@dmhai.local",
      user_role:  "admin",
      session_id: "S123"
    }

    case RunScript.provision(ctx) do
      {:ok, %{username: username, sandbox_cwd: cwd}} ->
        assert username == "dmh_ai-master-u"
        assert cwd == "/data/user_workspaces/admin@dmhai.local/S123"

      {:error, reason} ->
        # Host filesystem isn't available in unit env (no /data tree)
        # — that's fine. What we MUST NOT see is a `{:ok, …}` with
        # the widened cwd. The error path is acceptable; only the
        # `{:ok, %{sandbox_cwd: "/data/user_workspaces"}}` bug shape
        # is forbidden. R02 covers the success path under docker.
        assert is_binary(reason)
    end
  end

  test "non-admin success returns per-session sandbox_cwd" do
    ctx = %{
      user_id:    "u_real_user",
      user_email: "user@example.com",
      user_role:  "user",
      session_id: "S456"
    }

    case RunScript.provision(ctx) do
      {:ok, %{sandbox_cwd: cwd}} ->
        assert cwd == "/data/user_workspaces/user@example.com/S456"

      {:error, _reason} ->
        :ok
    end
  end

  test "missing session_id surfaces a clear error rather than silently widening cwd" do
    ctx = %{
      user_id:    "u_admin",
      user_email: "admin@dmhai.local",
      user_role:  "admin",
      session_id: ""
    }

    case RunScript.provision(ctx) do
      {:ok, %{sandbox_cwd: cwd}} ->
        refute cwd == "/data/user_workspaces",
               """
               provision/1 MUST NOT silently widen sandbox_cwd to the
               workspaces root when session_id is empty. Either return an
               error or fall through to a /tmp scratch dir — never grant
               the running process visibility into ALL users' workspaces.
               """

      {:error, _reason} ->
        :ok
    end
  end
end
