# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F24 — Loopback PUT /ai_pools idempotent import.
#
# `PUT /ai_pools` is the fresh-install bootstrap path: an operator
# `curl`s their `pools.json` to localhost without first having to log
# in as admin. Loopback-only by IP gate (Router checks
# `conn.remote_ip` against 127.x.x.x / ::1).
#
# The handler accepts BOTH the wrapped object shape `{"pools": [...]}`
# (matching the seed-file convention) AND the bare array shape
# (matching `/admin/pools/import_many`). It calls `Pools.create/1` per
# row; existing-name rows return `{:error, :name_taken}` and count as
# `skipped` — that's the idempotency contract.
#
# Validates the full handler surface end-to-end:
#
#   * 200 + correct summary on first import (all inserted).
#   * 200 + idempotent re-import (all skipped, no duplicates in DB).
#   * Bare-array body shape accepted equivalently.
#   * Validation errors surface in `errors` without aborting the
#     whole batch (so a bad row doesn't lose the good rows).
#   * Loopback gate — non-loopback IP returns 403.
#   * Malformed JSON returns 400.

defmodule DmhAi.Flows.F24AiPoolsBulkImport do
  use ExUnit.Case, async: false

  alias DmhAi.LLM.Pools
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F24"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F24")
    on_exit(teardown)
    :ok
  end

  setup do
    # Use uniquely-prefixed pool names so each test run is isolated.
    prefix = "f24-#{T.uid()}"

    on_exit(fn ->
      # Pool accounts embed in `pools.accounts` (JSON column), not
      # a separate table — single DELETE is enough.
      query!(Repo, "DELETE FROM pools WHERE name LIKE ?", [prefix <> "%"])
    end)

    %{prefix: prefix}
  end

  describe "wrapped {\"pools\": [...]} body" do
    test "first PUT inserts all rows; second PUT skips all", %{prefix: prefix} do
      pools = build_pools(prefix, 3)

      body =
        Jason.encode!(%{"pools" => pools})

      # First PUT — all inserted.
      conn1 = call_put_ai_pools(body, loopback: true)

      assert conn1.status == 200
      summary1 = Jason.decode!(conn1.resp_body)

      assert summary1["inserted"] == 3,
             "expected 3 inserted on first PUT; got: #{inspect(summary1)}"
      assert summary1["skipped"] == 0
      assert summary1["errors"] == []

      # Verify rows landed in DB.
      Enum.each(pools, fn p ->
        assert {:ok, pool} = Pools.fetch(p["name"])
        assert pool.protocol == p["protocol"]
        assert pool.base_url == p["base_url"]
      end)

      # Second PUT — same body. All skipped (idempotency contract).
      conn2 = call_put_ai_pools(body, loopback: true)

      assert conn2.status == 200
      summary2 = Jason.decode!(conn2.resp_body)

      assert summary2["inserted"] == 0,
             "expected 0 inserted on idempotent re-PUT; got: #{inspect(summary2)}"
      assert summary2["skipped"] == 3,
             "expected 3 skipped on idempotent re-PUT; got: #{inspect(summary2)}"
      assert summary2["errors"] == []

      # No duplicates created.
      %{rows: [[count]]} =
        query!(Repo, "SELECT COUNT(*) FROM pools WHERE name LIKE ?", [prefix <> "%"])
      assert count == 3,
             "DB should still hold exactly 3 pools after idempotent re-PUT; got: #{count}"
    end
  end

  describe "bare array body" do
    test "accepted equivalently to the wrapped shape", %{prefix: prefix} do
      pools = build_pools(prefix, 2)
      body = Jason.encode!(pools)

      conn = call_put_ai_pools(body, loopback: true)

      assert conn.status == 200
      summary = Jason.decode!(conn.resp_body)

      assert summary["inserted"] == 2
      assert summary["skipped"] == 0
      assert summary["errors"] == []
    end
  end

  describe "validation errors surface but don't abort the batch" do
    test "one bad + two good → 2 inserted, 0 skipped, 1 error", %{prefix: prefix} do
      good = build_pools(prefix, 2)

      bad = %{
        "name" => "#{prefix}-bad",
        # missing protocol / base_url → validate/1 returns :missing_fields
        "strategy" => "least_used"
      }

      body = Jason.encode!(%{"pools" => good ++ [bad]})

      conn = call_put_ai_pools(body, loopback: true)

      assert conn.status == 200
      summary = Jason.decode!(conn.resp_body)

      assert summary["inserted"] == 2,
             "good rows should still insert despite a bad sibling; got: #{inspect(summary)}"
      assert summary["skipped"] == 0

      assert is_list(summary["errors"]) and length(summary["errors"]) == 1,
             "expected exactly one error entry; got: #{inspect(summary["errors"])}"

      [err] = summary["errors"]
      assert err["name"] == "#{prefix}-bad",
             "error entry should name the offending row; got: #{inspect(err)}"
      assert is_binary(err["error"]) and err["error"] != ""
    end
  end

  describe "loopback gate" do
    test "non-loopback IP returns 403", %{prefix: prefix} do
      pools = build_pools(prefix, 1)
      body = Jason.encode!(%{"pools" => pools})

      conn = call_put_ai_pools(body, loopback: false)

      assert conn.status == 403,
             "non-loopback PUT must be rejected; got status=#{conn.status} body=#{conn.resp_body}"

      decoded = Jason.decode!(conn.resp_body)
      assert is_binary(decoded["error"])
      assert decoded["error"] =~ "loopback"

      # Nothing was imported.
      %{rows: [[count]]} =
        query!(Repo, "SELECT COUNT(*) FROM pools WHERE name LIKE ?", [prefix <> "%"])
      assert count == 0,
             "non-loopback PUT must not insert anything; got count=#{count}"
    end
  end

  describe "malformed body" do
    test "non-JSON body returns 400" do
      conn = call_put_ai_pools("this is not json", loopback: true)

      assert conn.status == 400
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"] =~ "valid JSON"
    end

    test "JSON of wrong shape (a bare object, not array) returns 400" do
      conn =
        call_put_ai_pools(Jason.encode!(%{"some_other_key" => "value"}), loopback: true)

      assert conn.status == 400
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"] =~ "pools"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp build_pools(prefix, n) do
    for i <- 1..n//1 do
      %{
        "name"      => "#{prefix}-pool-#{i}",
        "protocol"  => "ollama",
        "base_url"  => "http://stub-host-#{i}:11434",
        "strategy"  => "least_used",
        "num_ctx"   => 32_768,
        "accounts"  => [],
        "models"    => []
      }
    end
  end

  # Build a Plug.Conn for `PUT /ai_pools`, drive it through the live
  # `DmhAi.Router`, and return the response conn so the test can
  # inspect status/body. `loopback: true` sets remote_ip to
  # 127.0.0.1 (passes the gate); `false` uses 10.0.0.5 (rejected).
  defp call_put_ai_pools(body, opts) do
    loopback? = Keyword.get(opts, :loopback, true)
    remote_ip = if loopback?, do: {127, 0, 0, 1}, else: {10, 0, 0, 5}

    conn =
      Plug.Test.conn(:put, "/ai_pools", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, remote_ip)

    DmhAi.Router.call(conn, DmhAi.Router.init([]))
  end
end
