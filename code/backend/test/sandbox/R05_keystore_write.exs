# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R05.
#
# `SandboxUser.write_keystore_file/4` is the only sanctioned writer
# into `/data/user_assets/<email>/_keystore/`. Per-user secrets
# (SSH keys generated during oauth, etc) end up there. The contract:
#
#   * file lands at <assets>/<email>/_keystore/<rel_path>
#   * mode = exactly what the caller passed (typically 0600)
#   * owner = the consuming sandbox uid (so the per-uid process can
#     read it; if it stayed root-owned, the sandbox could only read
#     it as root, which it isn't)
#
# A regression where the chown is skipped breaks SSH-key consumption
# from the sandbox.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R05KeystoreWrite do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Permissions.SandboxUser

  test "write_keystore_file lands a 0600 file owned by the consuming uid" do
    ctx = SandboxCase.fresh_admin_ctx()

    # Build the fixture body at runtime so no source-code line looks
    # like a real SSH private key (per CLAUDE.md rule #13 — secret
    # scanners flag on shape, not on validity).
    fake_key = "FAKE-" <> "TEST-" <> String.duplicate("X", 64)

    assert {:ok, abs_path} =
             SandboxUser.write_keystore_file(
               %{role: "admin", id: ctx.user_id, email: ctx.user_email},
               "id_test",
               fake_key,
               0o600
             )

    expected_path =
      Path.join([
        System.get_env("DMHAI_TEST_TMP_DIR"),
        "user_assets",
        ctx.user_email,
        "_keystore",
        "id_test"
      ])

    assert abs_path == expected_path

    %{uid: uid, mode: mode} = File.stat!(abs_path)
    # File.stat returns mode as a full integer — the bottom 9 bits
    # are the permission bits (0o777 mask).
    assert Bitwise.band(mode, 0o777) == 0o600
    assert uid == 10000, "keystore file must be owned by sandbox runtime uid; got #{uid}"

    assert File.read!(abs_path) == fake_key
  end
end
