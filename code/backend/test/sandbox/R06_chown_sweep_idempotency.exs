# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R06.
#
# Pin down the contract that drives R02's pass: when master pre-
# creates a per-session workspace subdir as root, `SandboxUser.uid_for/1`
# must repair the ownership during the chown sweep regardless of
# whether the user-level dir was already provisioned earlier.
#
# Without this guarantee, a subdir that lands at session-start (root-
# owned via `File.mkdir_p` from master) before any run_script call
# stays root-owned, and the per-uid sandbox process can't write into
# it. That's exactly session 1778419904376's failure shape.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R06ChownSweepIdempotency do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Permissions.SandboxUser

  test "uid_for sweeps existing root-owned per-session subdirs into the master uid" do
    ctx = SandboxCase.fresh_admin_ctx()

    # Pre-state — master mkdirs the session subdir as root, the way
    # `UserAgent` does at chain start. The dir lands root:root mode
    # 755; the chown sweep is what's supposed to flip it to 10000.
    workspace_dir = Constants.session_workspace_dir(ctx.user_email, ctx.session_id)
    File.mkdir_p!(workspace_dir)
    %{uid: pre_uid} = File.stat!(workspace_dir)
    assert pre_uid == 0

    # Trigger the sweep. uid_for runs ensure_host_dirs + the
    # docker-exec'd recursive chown over /data/user_workspaces/<email>.
    assert {:ok, 10000} = SandboxUser.uid_for(%{role: "admin", email: ctx.user_email})

    %{uid: post_uid} = File.stat!(workspace_dir)
    assert post_uid == 10000,
           """
           expected per-session subdir to be chown'd to master uid 10000
           after uid_for/1; got #{post_uid}. The sweep must reach into
           pre-existing subdirs created earlier by master-as-root —
           a non-recursive chown would miss them and re-introduce the
           production EACCES failure.
           """

    # Idempotent — calling again is a no-op (no errors, ownership
    # unchanged).
    assert {:ok, 10000} = SandboxUser.uid_for(%{role: "admin", email: ctx.user_email})
    %{uid: idem_uid} = File.stat!(workspace_dir)
    assert idem_uid == 10000
  end
end
