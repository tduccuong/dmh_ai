# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R02.
#
# End-to-end happy path: admin role, master pre-creates the per-
# session workspace dir AS ROOT (mimicking the production
# `File.mkdir_p(workspace_dir)` calls in `UserAgent`), then a real
# `RunScript.execute/2` writes a file inside that dir from the
# sandbox container running as `dmh_ai-master-u` (uid 10000). The
# write MUST succeed, and the resulting file MUST live at the
# host-side path the FE/HTTP layer expects, owned by the runtime
# uid — i.e. the `provision/1` chown sweep must have repaired the
# root-owned subdir master left behind.
#
# This is the test that would have caught session 1778419904376's
# real-world failure (5 EACCES'd `cp` calls in a row).

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R02ProvisionWritesPerSession do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Tools.RunScript

  test "admin run_script lands a writable file under the per-session workspace" do
    ctx = SandboxCase.fresh_admin_ctx()

    # Step 1 — master pre-creates the per-session workspace dir.
    # Master runs as root in production, so this matches what
    # `UserAgent.dispatch_assistant/2` does at chain start (line
    # ~1001-1002 of user_agent.ex). Root-owned, mode 755.
    workspace_dir = Constants.session_workspace_dir(ctx.user_email, ctx.session_id)
    File.mkdir_p!(workspace_dir)
    %{uid: pre_uid} = File.stat!(workspace_dir)
    assert pre_uid == 0, "precondition: workspace_dir is created root-owned by master"

    # Step 2 — drive a real run_script. The script path is the same
    # shape that failed in 1778419904376: relative-to-cwd, no
    # absolute path. If `provision/1` regresses to widening cwd to
    # the workspaces root, this `cp` lands one tree above the
    # session and the host_workspace_path assertion below fails.
    script = "cp /etc/hostname ./out.txt"

    assert {:ok, result} = RunScript.execute(%{"script" => script}, ctx),
           "run_script must succeed; chown sweep should have fixed the root-owned workspace"

    refute String.contains?(to_string(result), "Permission denied"),
           "run_script result must not contain a Permission denied — got: #{inspect(result)}"

    # Step 3 — file lands at the host-side path the FE/HTTP layer
    # knows about, exactly under
    # <workspaces>/<email>/<session>/out.txt.
    host_path = SandboxCase.host_workspace_path(ctx, "out.txt")
    assert File.exists?(host_path),
           "expected file at #{host_path}; run_script wrote elsewhere"

    # Step 4 — ownership got swept from root (master-create) to
    # uid 10000 (master_uid — the consuming sandbox user). The
    # chown sweep is what repairs the inherent timing window:
    # master-as-root creates the dir, then the sandbox-as-uid-10000
    # tries to write inside it.
    assert SandboxCase.host_owner_uid(host_path) == 10000,
           "file must be owned by sandbox runtime uid (10000); got #{inspect(SandboxCase.host_owner_uid(host_path))}"
  end
end
