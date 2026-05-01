# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.Pools do
  use ExUnit.Case, async: false

  alias DmhAi.LLM.{Pools, AccountRotation}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    name = "test-pool-" <> T.uid()
    on_exit(fn ->
      query!(Repo, "DELETE FROM pools WHERE name=?", [name])
    end)
    {:ok, name: name}
  end

  describe "parse/1" do
    test "splits on the first ::, model can carry colons" do
      assert {:ok, "miner", "qwen3-embedding:0.6b"} = Pools.parse("miner::qwen3-embedding:0.6b")
      assert {:ok, "ollama-cloud", "gemma4:31b-cloud"} =
               Pools.parse("ollama-cloud::gemma4:31b-cloud")
    end

    test "rejects strings without a separator" do
      assert {:error, :invalid_format} = Pools.parse("not-a-pool-model")
      assert {:error, :invalid_format} = Pools.parse("")
    end

    test "rejects empty pool or empty model" do
      assert {:error, :invalid_format} = Pools.parse("::model")
      assert {:error, :invalid_format} = Pools.parse("pool::")
    end
  end

  describe "create/1 + fetch/1 + delete/1" do
    test "round trip and uniqueness", %{name: name} do
      assert {:ok, pool} =
               Pools.create(%{
                 "name" => name,
                 "provider" => "ollama",
                 "base_url" => "http://example.test/v1",
                 "accounts" => [%{"name" => "a1", "api_key" => "k1"}]
               })

      assert pool.name == name
      assert pool.provider == "ollama"
      assert [%{"name" => "a1", "api_key" => "k1"}] = pool.accounts

      assert {:ok, ^pool} = Pools.fetch(name)
      assert {:error, :name_taken} = Pools.create(%{
        "name" => name,
        "provider" => "ollama",
        "base_url" => "http://example.test/v1"
      })

      assert :ok = Pools.delete(pool.id)
      assert {:error, :unknown_pool} = Pools.fetch(name)
    end

    test "rejects missing required fields" do
      assert {:error, :missing_fields} = Pools.create(%{"name" => "incomplete"})
    end

    test "num_ctx: nil by default; integers persist; strings parse; garbage → nil", %{name: name} do
      {:ok, p1} = Pools.create(%{
        "name" => name <> "-a",
        "provider" => "ollama",
        "base_url" => "http://example.test"
      })
      assert p1.num_ctx == nil
      query!(Repo, "DELETE FROM pools WHERE name=?", [name <> "-a"])

      {:ok, p2} = Pools.create(%{
        "name" => name <> "-b",
        "provider" => "ollama",
        "base_url" => "http://example.test",
        "num_ctx" => 32768
      })
      assert p2.num_ctx == 32768
      query!(Repo, "DELETE FROM pools WHERE name=?", [name <> "-b"])

      {:ok, p3} = Pools.create(%{
        "name" => name <> "-c",
        "provider" => "ollama",
        "base_url" => "http://example.test",
        "num_ctx" => "16384"
      })
      assert p3.num_ctx == 16384
      query!(Repo, "DELETE FROM pools WHERE name=?", [name <> "-c"])

      {:ok, p4} = Pools.create(%{
        "name" => name <> "-d",
        "provider" => "ollama",
        "base_url" => "http://example.test",
        "num_ctx" => "abc"
      })
      assert p4.num_ctx == nil
      query!(Repo, "DELETE FROM pools WHERE name=?", [name <> "-d"])
    end

    test "update can flip num_ctx between value and nil", %{name: name} do
      {:ok, p} = Pools.create(%{
        "name" => name,
        "provider" => "ollama",
        "base_url" => "http://example.test",
        "num_ctx" => 8192
      })
      assert p.num_ctx == 8192

      {:ok, p2} = Pools.update(p.id, %{"num_ctx" => 16384})
      assert p2.num_ctx == 16384

      # Blank string from FE clears it back to nil.
      {:ok, p3} = Pools.update(p.id, %{"num_ctx" => ""})
      assert p3.num_ctx == nil
    end
  end

  describe "resolve/1" do
    test "returns endpoint + account fields for a known pool", %{name: name} do
      {:ok, _} = Pools.create(%{
        "name" => name,
        "provider" => "ollama",
        "base_url" => "http://example.test/v1",
        "accounts" => [%{"name" => "k1", "api_key" => "secret-1"}]
      })

      assert {:ok, resolved} = Pools.resolve(name <> "::some-model:7b")
      assert resolved.pool_name == name
      assert resolved.model == "some-model:7b"
      assert resolved.base_url == "http://example.test/v1"
      assert resolved.provider == "ollama"
      assert resolved.account_name == "k1"
      assert resolved.api_key == "secret-1"
    end

    test "rejects unknown pool" do
      assert {:error, :unknown_pool} = Pools.resolve("does-not-exist-#{T.uid()}::model")
    end

    test "rejects malformed strings" do
      assert {:error, :invalid_format} = Pools.resolve("no-colons-here")
    end
  end

  describe "AccountRotation" do
    test "least_used picks the account with the smallest last_used_ts", %{name: name} do
      {:ok, pool} = Pools.create(%{
        "name" => name,
        "provider" => "ollama",
        "base_url" => "http://example.test/v1",
        "strategy" => "least_used",
        "accounts" => [
          %{"name" => "old", "api_key" => "k-old", "last_used_ts" => 1_000},
          %{"name" => "new", "api_key" => "k-new", "last_used_ts" => 9_000}
        ]
      })

      assert {:ok, picked} = AccountRotation.pick(pool)
      assert picked["name"] == "old"
    end

    test "throttled accounts are filtered out, returns :all_throttled when none active", %{name: name} do
      future = System.os_time(:millisecond) + 60_000

      {:ok, pool} = Pools.create(%{
        "name" => name,
        "provider" => "ollama",
        "base_url" => "http://example.test/v1",
        "accounts" => [
          %{"name" => "blocked", "api_key" => "k1", "throttled_until" => future}
        ]
      })

      assert {:error, :all_throttled, retry} = AccountRotation.pick(pool)
      assert retry > 0 and retry <= 60_000
    end

    test "probe surfaces network failure as a string error" do
      alias DmhAi.LLM.Probe
      # Use a guaranteed-unroutable address so this is fast + offline-safe.
      assert {:error, msg} = Probe.probe("http://127.0.0.1:1", nil)
      assert is_binary(msg)
      assert msg =~ "Connection failed" or msg =~ "Connection refused" or msg =~ "econnrefused"
    end

    test "add_account / remove_account round trip", %{name: name} do
      {:ok, pool} = Pools.create(%{
        "name" => name,
        "provider" => "ollama",
        "base_url" => "http://example.test/v1"
      })
      assert pool.accounts == []

      {:ok, p1} = Pools.add_account(pool.id, "alice", "sk-AAA")
      assert length(p1.accounts) == 1
      assert hd(p1.accounts)["name"] == "alice"

      {:ok, p2} = Pools.add_account(pool.id, "bob", "sk-BBB")
      assert length(p2.accounts) == 2

      {:error, :name_taken} = Pools.add_account(pool.id, "alice", "sk-DUP")

      {:error, :missing_fields} = Pools.add_account(pool.id, "", "sk-X")
      {:error, :missing_fields} = Pools.add_account(pool.id, "x", "")

      {:ok, p3} = Pools.remove_account(pool.id, "alice")
      assert length(p3.accounts) == 1
      assert hd(p3.accounts)["name"] == "bob"

      # Removing a non-existent name is a no-op (idempotent).
      {:ok, p4} = Pools.remove_account(pool.id, "ghost")
      assert length(p4.accounts) == 1
    end

    test "mark_throttled persists across fetches", %{name: name} do
      {:ok, _} = Pools.create(%{
        "name" => name,
        "provider" => "ollama",
        "base_url" => "http://example.test/v1",
        "accounts" => [
          %{"name" => "a1", "api_key" => "k1"},
          %{"name" => "a2", "api_key" => "k2"}
        ]
      })

      until = System.os_time(:millisecond) + 60_000
      :ok = AccountRotation.mark_throttled(name, "a1", until)

      {:ok, refreshed} = Pools.fetch(name)
      a1 = Enum.find(refreshed.accounts, &(&1["name"] == "a1"))
      assert a1["throttled_until"] == until

      assert {:ok, picked} = AccountRotation.pick(refreshed)
      assert picked["name"] == "a2"
    end
  end
end
