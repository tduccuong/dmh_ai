# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.Init.PoolSeed do
  @moduledoc """
  Seed default pools on first boot. Importable from an operator-managed
  `pools.json` (see `load_pool_seeds/0` for path order). When no file is
  found, only the `ollama-cloud` placeholder is inserted so the admin UI
  has something to edit. Idempotent — re-run on every boot, but only
  inserts pools that don't already exist by name. Pools whose
  `protocol` is missing or invalid are skipped with a loud log line —
  the seed loader does not auto-translate older shapes.
  """

  require Logger
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  def seed_all do
    existing = query!(Repo, "SELECT name FROM pools", []).rows |> List.flatten() |> MapSet.new()

    seeds = load_pool_seeds()
    valid_protocols = DmhAi.LLM.Pools.valid_protocols()

    now = System.os_time(:millisecond)

    Enum.each(seeds, fn pool ->
      cond do
        MapSet.member?(existing, pool["name"]) ->
          :ok

        pool["protocol"] not in valid_protocols ->
          Logger.error(
            "[DB.Init] pool seed `#{pool["name"] || "(unnamed)"}` skipped: " <>
              "protocol=#{inspect(pool["protocol"])} not in #{inspect(valid_protocols)}"
          )

        true ->
          query!(Repo, """
          INSERT INTO pools (org_id, name, protocol, base_url, strategy,
                             cooldown_seconds, num_ctx, accounts, models,
                             rr_cursor, created_ts, updated_ts)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
          """, [
            DmhAi.Constants.default_org_id(),
            pool["name"],
            pool["protocol"],
            pool["base_url"],
            pool["strategy"] || "least_used",
            pool["cooldown_seconds"] || 300,
            pool["num_ctx"],
            Jason.encode!(pool["accounts"] || []),
            Jason.encode!(pool["models"] || []),
            now, now
          ])
          Logger.info("[DB.Init] seeded pool: #{pool["name"]}")
      end
    end)
  end

  # Look for an operator-managed pool seed file. Path order:
  #   1. $DMHAI_POOL_SEED  — explicit override
  #   2. /data/pools.json — operator file bind-mounted into the container
  #   3. ./temp/pools.json — repo-local copy used in dev
  # Falls back to a built-in placeholder set if none of those exist.
  defp load_pool_seeds do
    candidate_paths = [
      System.get_env("DMHAI_POOL_SEED"),
      "/data/pools.json",
      "temp/pools.json"
    ]
    |> Enum.reject(&is_nil/1)

    case Enum.find(candidate_paths, &File.exists?/1) do
      nil ->
        default_pool_seeds()

      path ->
        try do
          %{"pools" => pools} = path |> File.read!() |> Jason.decode!()
          Enum.map(pools, fn p ->
            accounts =
              (p["accounts"] || [])
              |> Enum.map(fn a ->
                %{
                  "name"    => a["name"] || a["api_key"] || "unknown",
                  "api_key" => a["api_key"] || a["apiKey"] || a["key"] || ""
                }
              end)

            Map.put(p, "accounts", accounts)
          end)
        rescue
          e ->
            Logger.warning("[DB.Init] pool seed file #{path} unreadable (#{Exception.message(e)}); using defaults")
            default_pool_seeds()
        end
    end
  end

  defp default_pool_seeds do
    [
      %{
        "name" => "ollama-cloud",
        "protocol" => "openai",
        "base_url" => "https://ollama.com/v1",
        "strategy" => "least_used",
        "cooldown_seconds" => 300,
        "accounts" => []
      }
    ]
  end
end
