# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R04.
#
# `user_assets` is mounted READ-ONLY into the sandbox container in
# production (`dist/docker-compose.yml: …:/data/user_assets:ro`).
# Run-script writes that try to land in user_assets MUST fail with
# a read-only-fs error from the kernel — this is the load-bearing
# fence that keeps the sandbox-side process from clobbering files
# the master writes (uploads, keystore, OAuth state).
#
# A regression where compose drops `:ro` (or someone "fixes" a
# permission error by widening to RW) would let any model-authored
# `cp` overwrite credentials. This test pins down the mount mode
# directly by running a touch from the sandbox-side and asserting
# EROFS, regardless of file permissions.
#
# CAVEAT: in `scripts/test.sandbox.sh` we mount user_assets RW (not
# `:ro`) so other tests can exercise SandboxUser.write_keystore_file
# end-to-end. R04 therefore goes through a SECOND sandbox sister
# container — booted on demand inside the test — that has the
# user_assets mount with `:ro`. That container exists only for the
# scope of this test.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R04AssetsMountReadonly do
  use DmhAi.Test.SandboxCase

  test "user_assets RO mount rejects sandbox-side writes with read-only-fs" do
    tmp_dir = System.get_env("DMHAI_TEST_TMP_DIR")
    rand    = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    name    = "dmh_test_ro_#{rand}_sandbox"

    # Boot a second sandbox sister with the production-shaped RO
    # mount on user_assets. Tear it down regardless of test outcome.
    {_, 0} = System.cmd("docker", [
      "run", "-d", "--name", name,
      "-v", "#{tmp_dir}/user_assets:/data/user_assets:ro",
      "dmh-ai-sandbox:latest",
      "tail", "-f", "/dev/null"
    ])

    on_exit(fn ->
      System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)
    end)

    # Wait for the container to be ready for `docker exec`.
    Enum.reduce_while(1..10, nil, fn _, _ ->
      case System.cmd("docker", ["exec", name, "true"], stderr_to_stdout: true) do
        {_, 0} -> {:halt, :ok}
        _      -> Process.sleep(200); {:cont, nil}
      end
    end)

    # Probe: any sandbox-side write into /data/user_assets MUST fail.
    {output, code} = System.cmd("docker", [
      "exec", name, "sh", "-c",
      "touch /data/user_assets/probe_should_fail 2>&1; echo EXIT=$?"
    ], stderr_to_stdout: true)

    assert code == 0  # the wrapping sh succeeds; we read the inner exit
    assert String.contains?(output, "Read-only file system"),
           "expected EROFS from kernel; got: #{output}"
    refute String.contains?(output, "EXIT=0"),
           "touch should NOT succeed on a RO mount"
  end
end
