# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F25 — fresh-install boot to first chat (unit-level slice).
#
# The full HTTP-layer flow (Bandit + login + change-password + first
# chat) is validated by the live stage smoke (#274). Here we cover the
# unit-level invariants the boot fix (#269) introduced:
#
#   * `DB.Init.run/0` is idempotent on an already-populated schema.
#   * After `run/0`, the default `admin@dmhai.local` user exists with
#     `role = "admin"`.
#   * `seed_admin/0` is also idempotent — re-running doesn't create
#     duplicate admin rows.
#
# A regression in any of the above re-introduces the boot crash-loop
# the schema-init phase was added to prevent.

defmodule DmhAi.Flows.F25FreshInstallBootToChat do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F25"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F25")
    on_exit(teardown)
    :ok
  end

  test "DB.Init.run/0 is idempotent and seeds the default admin" do
    # 1. The suite's `test_helper.exs` boot already ran the schema
    #    init once. Verify the schema is in place: the admin row
    #    must exist with role='admin'.
    %{rows: rows} = query!(Repo,
      "SELECT email, role FROM users WHERE email = ?", ["admin@dmhai.local"])

    assert match?([[_email, "admin"]], rows),
           "default admin@dmhai.local row should exist with role='admin' after boot; got: #{inspect(rows)}"

    [[email, role]] = rows
    assert email == "admin@dmhai.local"
    assert role  == "admin"

    # 2. Snapshot the row count, then re-run the schema init.
    %{rows: [[before_count]]} = query!(Repo, "SELECT COUNT(*) FROM users", [])

    # `DB.Init.run/0` walks the same idempotent CREATE TABLE IF NOT
    # EXISTS path the runtime uses on every container start.
    DmhAi.DB.Init.run()

    %{rows: [[after_count]]} = query!(Repo, "SELECT COUNT(*) FROM users", [])

    assert after_count == before_count,
           "DB.Init.run/0 must be idempotent — user count changed from #{before_count} to #{after_count}"

    # 3. Admin row count unchanged — re-seeding must not duplicate.
    %{rows: [[admin_count]]} = query!(Repo,
      "SELECT COUNT(*) FROM users WHERE email = ?", ["admin@dmhai.local"])

    assert admin_count == 1,
           "default admin should be exactly 1 row after re-seed; got: #{admin_count}"
  end
end
