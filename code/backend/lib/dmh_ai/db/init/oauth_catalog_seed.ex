# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.Init.OAuthCatalogSeed do
  @moduledoc """
  Curated OAuth catalog seed. Two-layer load:

    1. `priv/oauth_catalog_default.json` — shipped with every release.
       Pre-populates ~20 popular providers (Google, Microsoft, GitHub,
       Slack, etc.), each with `enabled = 0` and empty credentials. The
       operator opens the admin UI and fills in client_id/secret to
       activate.
    2. Optional operator override file (env var or `/data` path) —
       UPSERTed by slug, replaces the priv default for matching slugs
       and adds new ones.

  Only runs when the table is empty (idempotent for redeploys).
  Subsequent edits go through the admin UI, not the seed loader.
  """

  require Logger
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 2, query!: 3]

  def seed_all do
    %{rows: [[count]]} = query!(Repo, "SELECT COUNT(*) FROM oauth_catalog")
    if count == 0, do: do_seed_oauth_catalog()
  end

  defp do_seed_oauth_catalog do
    priv_seeds     = load_priv_oauth_catalog_seeds()
    operator_seeds = load_operator_oauth_catalog_seeds()

    # Operator overrides win on slug collision. Build a slug-keyed
    # map so the order is irrelevant; final list preserves operator
    # additions on top of priv defaults.
    by_slug =
      Enum.reduce(priv_seeds ++ operator_seeds, %{}, fn entry, acc ->
        Map.put(acc, entry["slug"], entry)
      end)

    final = Map.values(by_slug)

    if final == [] do
      Logger.info("[DB.Init] no oauth_catalog seeds found; catalog starts empty")
    else
      now = System.os_time(:millisecond)

      Enum.each(final, fn entry -> insert_oauth_catalog_row(entry, now) end)
    end
  end

  defp insert_oauth_catalog_row(entry, now) do
    scopes_json     = entry["scopes_default"] |> List.wrap() |> Jason.encode!()
    extra_auth      = (entry["extra_auth_params"]  || %{}) |> Jason.encode!()
    extra_token     = (entry["extra_token_params"] || %{}) |> Jason.encode!()

    try do
      query!(Repo, """
      INSERT INTO oauth_catalog
        (slug, display_name, host_match,
         authorization_endpoint, token_endpoint,
         scopes_default, client_id, client_secret,
         extra_auth_params, extra_token_params,
         userinfo_endpoint, userinfo_field_path,
         enabled, created_ts, updated_ts)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [
        entry["slug"],
        entry["display_name"],
        entry["host_match"],
        entry["authorization_endpoint"],
        entry["token_endpoint"],
        scopes_json,
        entry["client_id"] || "",
        entry["client_secret"],
        extra_auth,
        extra_token,
        entry["userinfo_endpoint"],
        entry["userinfo_field_path"],
        if(entry["enabled"] == true, do: 1, else: 0),
        now,
        now
      ])

      Logger.info("[DB.Init] seeded oauth_catalog: #{entry["slug"]}")
    rescue
      e ->
        Logger.warning("[DB.Init] oauth_catalog seed `#{entry["slug"]}` failed: #{Exception.message(e)}")
    end
  end

  # Read the always-shipped seed file from `priv/`. Lives inside the
  # release artifact so every fresh install has the popular providers
  # pre-listed (disabled, no secrets).
  defp load_priv_oauth_catalog_seeds do
    path = Path.join(:code.priv_dir(:dmh_ai), "oauth_catalog_default.json")
    read_oauth_catalog_seed_file(path, log_missing: false)
  end

  # Look for an OPTIONAL operator-managed override file. Path order:
  #   1. $DMHAI_OAUTH_CATALOG_SEED — explicit override
  #   2. /data/oauth_catalog.json — operator file bind-mounted into the container
  #   3. ./temp/oauth_catalog.json — repo-local copy used in dev
  # Operators normally use the admin UI; this file path is for
  # bulk imports / disaster recovery. Returns [] when no file is found.
  defp load_operator_oauth_catalog_seeds do
    [
      System.get_env("DMHAI_OAUTH_CATALOG_SEED"),
      "/data/oauth_catalog.json",
      "temp/oauth_catalog.json"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&File.exists?/1)
    |> case do
      nil  -> []
      path -> read_oauth_catalog_seed_file(path, log_missing: true)
    end
  end

  defp read_oauth_catalog_seed_file(path, opts) do
    if File.exists?(path) do
      try do
        %{"services" => services} = path |> File.read!() |> Jason.decode!()
        List.wrap(services)
      rescue
        e ->
          Logger.warning("[DB.Init] oauth_catalog seed file #{path} unreadable (#{Exception.message(e)})")
          []
      end
    else
      if Keyword.get(opts, :log_missing, false) do
        Logger.info("[DB.Init] oauth_catalog seed file #{path} not present; skipping")
      end
      []
    end
  end
end
