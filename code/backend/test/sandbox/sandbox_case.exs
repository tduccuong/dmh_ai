# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Test.SandboxCase do
  @moduledoc """
  ExUnit case template for the sandbox-runtime tier.

  These tests run INSIDE an ephemeral elixir runner container that
  has a sister `dmh-ai-sandbox` container booted by
  `scripts/test.sandbox.sh`. The runner is master-shaped: runs as
  root (so it can chown files into the per-uid layout the production
  sandbox expects), has the docker socket mounted (so it can `docker
  exec` against the sister sandbox), and shares a throwaway data dir
  with the sandbox at the same `/data/...` paths production uses
  (per CLAUDE.md rule #17 — same host dir, same container path).

  The orchestration script passes two env vars in:

    * `DMHAI_TEST_SANDBOX_CONTAINER` — the sister sandbox container's
      name. `Sandbox.container_name/0` reads this at runtime so
      production code paths (run_script's docker exec, the chown
      sweep) target the test sandbox without any test-specific
      branching.
    * `DMHAI_TEST_TMP_DIR` — the throwaway host directory mounted as
      `/data` in both the runner and the sandbox. Constants paths
      (`assets_dir`, `workspaces_dir`, `db_path`, `log_file`) are
      pinned to subpaths underneath via `Application.put_env(:dmh_ai,
      :paths, ...)` in `setup_all`.

  Each test gets its own throwaway USER (random email) and SESSION
  (random session_id) so per-test state doesn't bleed. The full
  filesystem tree (`/data/db`, `/data/user_assets`, …) is shared,
  which mirrors production where many users live in one
  `user_workspaces/`.

  Hard fail when the env vars are missing — these tests are
  meaningless outside the runner, and a silent fall-through to the
  host's actual `/data` would risk clobbering the operator's stage
  data.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      @moduletag :sandbox

      alias DmhAi.Test.SandboxCase
      alias DmhAi.Tools.RunScript
      alias DmhAi.Permissions.SandboxUser
      alias DmhAi.Constants
    end
  end

  setup_all do
    sandbox = System.get_env("DMHAI_TEST_SANDBOX_CONTAINER") ||
      flunk_outside_runner("DMHAI_TEST_SANDBOX_CONTAINER")

    tmp_dir = System.get_env("DMHAI_TEST_TMP_DIR") ||
      flunk_outside_runner("DMHAI_TEST_TMP_DIR")

    unless File.dir?(tmp_dir) do
      raise "DMHAI_TEST_TMP_DIR points at #{tmp_dir} which doesn't exist — orchestration script broke?"
    end

    Application.put_env(:dmh_ai, :paths, %{
      assets_dir:     Path.join(tmp_dir, "user_assets"),
      workspaces_dir: Path.join(tmp_dir, "user_workspaces"),
      db_path:        Path.join(tmp_dir, "db/chat.db"),
      log_file:       Path.join(tmp_dir, "system_logs/system.log")
    })

    Application.put_env(:dmh_ai, :sandbox_container_name, sandbox)

    {:ok, sandbox: sandbox, tmp_dir: tmp_dir}
  end

  @doc """
  Build a per-test admin context. Random email + session_id so two
  parallel tests don't collide on the host filesystem.
  """
  def fresh_admin_ctx do
    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    %{
      user_id:    "u_admin_#{rand}",
      user_email: "admin_#{rand}@dmhai.test",
      user_role:  "admin",
      session_id: "S#{rand}"
    }
  end

  @doc """
  Resolve the host-side path of a per-session workspace file. Tests
  that wrote into `<workspace>/foo.txt` from the sandbox check it
  exists at this host path.
  """
  def host_workspace_path(ctx, rel_path) do
    Path.join([
      System.get_env("DMHAI_TEST_TMP_DIR"),
      "user_workspaces",
      ctx.user_email,
      ctx.session_id,
      rel_path
    ])
  end

  @doc """
  Owner uid of a host file. Used for ownership-correctness assertions.
  Returns the integer uid, or nil if the file doesn't exist.
  """
  def host_owner_uid(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{uid: uid}} -> uid
      _                  -> nil
    end
  end

  defp flunk_outside_runner(var) do
    raise """
    #{var} is not set — sandbox-runtime tests must run inside the
    ephemeral runner started by `scripts/test.sandbox.sh`. Plain
    `mix test test/sandbox/` from the host won't work; use:

        ./scripts/test.sandbox.sh [R<NN>...]

    See architecture.md §Testing → Runtime tier.
    """
  end
end
