# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.MCP.Catalog do
  @moduledoc """
  Admin-curated MCP service catalog. CRUD plus an `enable/1`
  preflight that runs `DmhAi.MCP.Probe.classify/1` against the
  service URL, classifies the auth model, and persists the metadata
  needed by `connect_mcp(slug:)` to skip discovery on user-side
  invocations.

  See specs/mcp.md §Phase E.
  """

  alias DmhAi.Repo
  alias DmhAi.MCP.Probe
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @type entry :: %{
          id: integer(),
          slug: String.t(),
          name: String.t(),
          description: String.t() | nil,
          mcp_url: String.t(),
          icon_url: String.t() | nil,
          categories: [String.t()],
          enabled: boolean(),
          auth_kind: String.t() | nil,
          auth_metadata: map() | nil,
          last_probe_status: String.t() | nil,
          last_probe_error: String.t() | nil,
          last_probe_at: integer() | nil,
          created_at: integer(),
          updated_at: integer()
        }

  # ── list / get ────────────────────────────────────────────────────────

  @spec list() :: [entry()]
  def list do
    %{rows: rows} = query!(Repo, """
    SELECT id, slug, name, description, mcp_url, icon_url, categories,
           enabled, auth_kind, auth_metadata,
           last_probe_status, last_probe_error, last_probe_at,
           created_at, updated_at
    FROM mcp_catalog ORDER BY id ASC
    """, [])

    Enum.map(rows, &row_to_map/1)
  end

  @spec get(integer()) :: entry() | nil
  def get(id) when is_integer(id) do
    case query!(Repo, "SELECT id, slug, name, description, mcp_url, icon_url, categories, enabled, auth_kind, auth_metadata, last_probe_status, last_probe_error, last_probe_at, created_at, updated_at FROM mcp_catalog WHERE id=?", [id]) do
      %{rows: [row | _]} -> row_to_map(row)
      _                  -> nil
    end
  end

  @spec get_by_slug(String.t()) :: entry() | nil
  def get_by_slug(slug) when is_binary(slug) do
    case query!(Repo, "SELECT id, slug, name, description, mcp_url, icon_url, categories, enabled, auth_kind, auth_metadata, last_probe_status, last_probe_error, last_probe_at, created_at, updated_at FROM mcp_catalog WHERE slug=?", [slug]) do
      %{rows: [row | _]} -> row_to_map(row)
      _                  -> nil
    end
  end

  # ── create / update / delete ──────────────────────────────────────────

  @spec create(map()) :: {:ok, entry()} | {:error, atom()}
  def create(attrs) do
    slug = String.trim(get_str(attrs, "slug"))
    name = String.trim(get_str(attrs, "name"))
    url  = String.trim(get_str(attrs, "mcp_url"))

    cond do
      slug == "" -> {:error, :missing_slug}
      name == "" -> {:error, :missing_name}
      url  == "" -> {:error, :missing_url}
      get_by_slug(slug) != nil -> {:error, :slug_taken}
      true ->
        now = System.os_time(:millisecond)

        query!(Repo, """
        INSERT INTO mcp_catalog (slug, name, description, mcp_url, icon_url, categories, enabled, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
        """, [
          slug,
          name,
          get_str_or_nil(attrs, "description"),
          url,
          get_str_or_nil(attrs, "icon_url"),
          encode_categories(attrs["categories"] || attrs[:categories]),
          now, now
        ])

        {:ok, get_by_slug(slug)}
    end
  end

  @spec update(integer(), map()) :: {:ok, entry()} | {:error, atom()}
  def update(id, attrs) when is_integer(id) do
    case get(id) do
      nil -> {:error, :not_found}

      _row ->
        # Build a partial UPDATE — only fields present in `attrs` move.
        {sets, args} =
          [
            {"name",        get_str_or_nil(attrs, "name")},
            {"description", get_str_or_nil(attrs, "description")},
            {"mcp_url",     get_str_or_nil(attrs, "mcp_url")},
            {"icon_url",    get_str_or_nil(attrs, "icon_url")},
            {"categories",  if(Map.has_key?(attrs, "categories") or Map.has_key?(attrs, :categories), do: encode_categories(attrs["categories"] || attrs[:categories]), else: :__skip__)}
          ]
          |> Enum.reject(fn {_, v} -> v == :__skip__ end)
          |> Enum.reduce({[], []}, fn {col, val}, {sets, args} ->
            {sets ++ ["#{col}=?"], args ++ [val]}
          end)

        if sets == [] do
          {:ok, get(id)}
        else
          now      = System.os_time(:millisecond)
          set_sql  = (sets ++ ["updated_at=?"]) |> Enum.join(", ")
          full_args = args ++ [now, id]

          query!(Repo, "UPDATE mcp_catalog SET #{set_sql} WHERE id=?", full_args)
          {:ok, get(id)}
        end
    end
  end

  @spec delete(integer()) :: :ok | {:error, :not_found}
  def delete(id) when is_integer(id) do
    case get(id) do
      nil -> {:error, :not_found}
      _   ->
        query!(Repo, "DELETE FROM mcp_catalog WHERE id=?", [id])
        :ok
    end
  end

  # ── enable / disable ──────────────────────────────────────────────────

  @doc """
  Run the preflight probe on a catalog row and persist the result:

    * Probe succeeds (`:open` or `{:gated, _}`) → `enabled=1`,
      `auth_kind` set, `auth_metadata` carries any PRM hint, and
      `last_probe_status` reflects the classification. Returns
      `{:ok, entry}`.

    * Probe returns `:not_mcp` or raises → `enabled=0`,
      `last_probe_status="not_mcp"` (or `"error"`),
      `last_probe_error` set. Returns `{:error, reason}` so the
      admin UI surfaces the failure inline.

  Disable is the trivial inverse — just flips `enabled` without
  re-probing or touching the cached metadata.
  """
  @spec enable(integer()) :: {:ok, entry()} | {:error, atom() | String.t()}
  def enable(id) when is_integer(id) do
    case get(id) do
      nil -> {:error, :not_found}

      %{mcp_url: url} = row ->
        now = System.os_time(:millisecond)

        try do
          case Probe.classify(url) do
            :open ->
              persist_probe(row.id, true, "none", %{}, "open", nil, now)
              {:ok, get(row.id)}

            {:gated, prm_hint} ->
              meta = %{"prm_hint" => prm_hint}
              persist_probe(row.id, true, "oauth", meta, "gated", nil, now)
              {:ok, get(row.id)}

            :not_mcp ->
              persist_probe(row.id, false, nil, nil, "not_mcp",
                "URL did not respond as an MCP server (initialize failed).", now)
              {:error, :not_mcp}
          end
        rescue
          e ->
            msg = Exception.message(e)
            Logger.warning("[Catalog] enable probe raised id=#{row.id} url=#{url}: #{msg}")
            persist_probe(row.id, false, nil, nil, "error", msg, now)
            {:error, msg}
        end
    end
  end

  @spec disable(integer()) :: {:ok, entry()} | {:error, :not_found}
  def disable(id) when is_integer(id) do
    case get(id) do
      nil -> {:error, :not_found}

      _ ->
        now = System.os_time(:millisecond)
        query!(Repo, "UPDATE mcp_catalog SET enabled=0, updated_at=? WHERE id=?", [now, id])
        {:ok, get(id)}
    end
  end

  # ── import ────────────────────────────────────────────────────────────

  @doc """
  Bulk-insert from a list of `attrs` maps. Skips rows whose slug
  already exists (no overwrite). Returns a summary
  `%{inserted: N, skipped: M, errors: [{slug, reason}, …]}`.
  """
  @spec import_many([map()]) :: map()
  def import_many(rows) when is_list(rows) do
    init = %{inserted: 0, skipped: 0, errors: []}

    Enum.reduce(rows, init, fn attrs, acc ->
      case create(attrs) do
        {:ok, _row} ->
          %{acc | inserted: acc.inserted + 1}

        {:error, :slug_taken} ->
          %{acc | skipped: acc.skipped + 1}

        {:error, reason} ->
          %{acc | errors: [{get_str(attrs, "slug"), reason} | acc.errors]}
      end
    end)
  end

  # ── private ───────────────────────────────────────────────────────────

  defp persist_probe(id, enabled?, auth_kind, auth_metadata, status, error, now) do
    query!(Repo, """
    UPDATE mcp_catalog
    SET enabled=?, auth_kind=?, auth_metadata=?,
        last_probe_status=?, last_probe_error=?, last_probe_at=?, updated_at=?
    WHERE id=?
    """, [
      if(enabled?, do: 1, else: 0),
      auth_kind,
      if(is_map(auth_metadata), do: Jason.encode!(auth_metadata), else: nil),
      status,
      error,
      now,
      now,
      id
    ])
  end

  defp row_to_map([id, slug, name, description, mcp_url, icon_url, categories,
                   enabled, auth_kind, auth_metadata,
                   last_probe_status, last_probe_error, last_probe_at,
                   created_at, updated_at]) do
    %{
      id:                id,
      slug:              slug,
      name:              name,
      description:       description,
      mcp_url:           mcp_url,
      icon_url:          icon_url,
      categories:        decode_categories(categories),
      enabled:           enabled == 1,
      auth_kind:         auth_kind,
      auth_metadata:     decode_auth_metadata(auth_metadata),
      last_probe_status: last_probe_status,
      last_probe_error:  last_probe_error,
      last_probe_at:     last_probe_at,
      created_at:        created_at,
      updated_at:        updated_at
    }
  end

  defp encode_categories(nil), do: nil
  defp encode_categories(list) when is_list(list), do: Jason.encode!(list)
  defp encode_categories(_), do: nil

  defp decode_categories(nil), do: []
  defp decode_categories(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _                              -> []
    end
  end

  defp decode_auth_metadata(nil), do: nil
  defp decode_auth_metadata(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) -> m
      _                       -> nil
    end
  end

  defp get_str(attrs, key) do
    val = attrs[key] || attrs[String.to_atom(key)]
    if is_binary(val), do: val, else: ""
  end

  defp get_str_or_nil(attrs, key) do
    val = attrs[key] || attrs[String.to_atom(key)]
    cond do
      is_binary(val) and val != "" -> val
      true -> nil
    end
  end
end
