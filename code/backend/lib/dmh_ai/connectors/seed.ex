# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Seed do
  @moduledoc """
  First-deploy seed loader. For each registered connector × each
  discoverable layer, check whether the DB has any rows for that
  (slug, layer). If empty, load the bundled seed from
  `priv/connectors/<slug>/<layer>.json` and populate the table.

  Layout:

      priv/connectors/<slug>/
        functions.json   — Layer A (function contracts)
        docs_seed.json   — Layer C (URLs to crawl on `Discover Docs` click)
        metadata_paths.json — Layer B (paths the model can query)

  The seed is bundled with the release so a brand-new deploy works
  without an admin first having to click Discover for every layer.
  The admin can still Discover at any time to refresh from the
  vendor's live API.

  Idempotent: re-running on a populated DB is a no-op. Use
  `force: true` to wipe + reseed (admin reset path).
  """

  require Logger

  alias DmhAi.Connectors.{Manifest, Registry}

  @doc """
  Run the seed for every registered connector × every discoverable
  layer. Called at boot from `Connectors.Bootstrap`.
  """
  @spec seed_all(keyword()) :: :ok
  def seed_all(opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    Registry.universal_modules()
    |> Enum.each(fn mod ->
      slug = mod.mcp_slug()

      :ok = seed_functions(slug, force?)
      # Layer B (per-user metadata) doesn't seed; populated on
      # first user-driven inspect_function_property call.
      # Layer C (docs) seed lands as part of #505 admin tooling.
    end)

    :ok
  end

  @doc """
  Seed Layer A (functions) for one connector. Reads
  `priv/connectors/<slug>/functions.json` and runs `Manifest.replace_all/3`
  every boot, so edits to the bundled JSON propagate without an explicit
  reseed. The replace is idempotent — same rows in produce the same rows
  out. `force?` is kept for the callsite signature but no longer
  short-circuits anything; it remains a no-op flag for callers.
  """
  @spec seed_functions(String.t(), boolean()) :: :ok
  def seed_functions(slug, force? \\ false)

  def seed_functions(slug, _force?) when is_binary(slug) do
    case load_seed_file(slug, "functions.json") do
      {:ok, rows} ->
        {:ok, n} = Manifest.replace_all(slug, rows, "seed")
        log_discovery_run(slug, "functions", :success, n, nil, "seed")
        Logger.info("[Connectors.Seed] slug=#{slug} functions seeded n=#{n}")
        :ok

      {:error, :not_found} ->
        Logger.info("[Connectors.Seed] slug=#{slug} no priv/connectors/#{slug}/functions.json — skipping")
        :ok

      {:error, reason} ->
        Logger.warning("[Connectors.Seed] slug=#{slug} seed failed: #{inspect(reason)}")
        log_discovery_run(slug, "functions", :failed, 0, inspect(reason), "seed")
        :ok
    end
  end

  @doc """
  Read + normalise `priv/connectors/<slug>/functions.json` into the
  shape `Manifest.replace_all/3` expects. Public so connector modules
  can implement `Discoverable.discover_functions/0` by delegating to
  the bundled seed when a vendor probe is unavailable or fails.
  """
  @spec read_priv_rows(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_priv_rows(slug) when is_binary(slug),
    do: load_seed_file(slug, "functions.json")

  # ─── private ─────────────────────────────────────────────────────────

  defp load_seed_file(slug, file) do
    path = Path.join([:code.priv_dir(:dmh_ai), "connectors", slug, file])

    case File.read(path) do
      {:ok, body} ->
        with {:ok, json}  <- Jason.decode(body),
             {:ok, rows}  <- extract_function_rows(json) do
          {:ok, rows}
        else
          {:error, _} = err -> err
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  defp extract_function_rows(%{"functions" => list}) when is_list(list) do
    {:ok, Enum.map(list, &normalise_row/1)}
  end

  defp extract_function_rows(%{}),
    do: {:error, "seed file must have `functions: [...]`"}

  defp extract_function_rows(_),
    do: {:error, "seed file root must be a JSON object"}

  defp normalise_row(%{} = row) do
    %{
      function_name:        Map.fetch!(row, "function_name"),
      permission:           String.to_atom(row["permission"] || "read"),
      args:                 row["args"] || %{},
      returns:              row["returns"] || %{},
      error_classes:        row["error_classes"] || [],
      scopes_required:      row["scopes_required"] || [],
      idempotency_key:      String.to_atom(row["idempotency_key"] || "none"),
      callable_from:        (row["callable_from"] || ["chat", "task"]) |> Enum.map(&String.to_atom/1),
      poll_trigger_capable: row["poll_trigger_capable"] || false,
      cursor_arg:           row["cursor_arg"],
      cursor_response_path: row["cursor_response_path"],
      items_path:           row["items_path"],
      min_poll_seconds:     row["min_poll_seconds"],
      default_poll_seconds: row["default_poll_seconds"],
      vendor_endpoint_hint: row["vendor_endpoint_hint"]
    }
  end

  defp log_discovery_run(slug, layer, status, n, err_text, triggered_by) do
    now = System.os_time(:millisecond)

    import Ecto.Adapters.SQL, only: [query!: 3]

    query!(DmhAi.Repo, """
    INSERT INTO connector_discovery_runs
      (connector_slug, layer, status, started_at, completed_at,
       error_text, records_affected, triggered_by, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [slug, layer, to_string(status), now, now, err_text, n, triggered_by, now])
  end
end
