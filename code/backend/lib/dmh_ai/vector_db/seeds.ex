# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.Seeds do
  @moduledoc """
  Wiki Seeds — admin-curated URLs that feed the global
  `:knowledge` scope via the same `/wiki <url>` pipeline. Sugar over
  `/wiki` with a pre-loaded list of well-known platform docs to save
  the admin from having to discover URLs themselves.

  See specs/vector_kb.md §"Wiki Seeds".
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @preloaded_path "priv/kb_seeds/preloaded.json"

  @doc """
  Idempotent merge of `priv/kb_seeds/preloaded.json` into `kb_seeds`.
  Inserts only URLs not already present — admin edits are never
  overwritten. Called automatically on first admin visit to
  /admin/wiki-seeds.
  """
  @spec ensure_preloaded() :: :ok
  def ensure_preloaded do
    path = Path.join(:code.priv_dir(:dmh_ai) |> to_string() |> Path.dirname() |> Path.dirname(), @preloaded_path)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) -> insert_missing(list)
          _ ->
            Logger.warning("[Seeds] #{path} unreadable JSON")
            :ok
        end

      {:error, _} ->
        # Try repo-relative fallback (dev / mix test before priv copy)
        fallback = Path.join(File.cwd!(), @preloaded_path)
        case File.read(fallback) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, list} when is_list(list) -> insert_missing(list)
              _ -> :ok
            end
          {:error, _} ->
            Logger.info("[Seeds] no preloaded.json at #{path} or #{fallback}; skipping seed")
            :ok
        end
    end
  end

  @doc "List all seed rows."
  @spec list() :: [map()]
  def list do
    query!(Repo, """
    SELECT id, url, label, tags, last_run_at, last_status, last_error, created_at
    FROM kb_seeds ORDER BY id ASC
    """, []).rows
    |> Enum.map(&row_to_map/1)
  end

  @doc "Add a new seed. Returns `{:ok, row}` or `{:error, :url_taken}` / `{:error, :missing_url}`."
  @spec create(map()) :: {:ok, map()} | {:error, atom()}
  def create(attrs) do
    url = String.trim(attrs["url"] || attrs[:url] || "")

    cond do
      url == "" ->
        {:error, :missing_url}

      true ->
        case fetch_by_url(url) do
          {:ok, _} ->
            {:error, :url_taken}

          :not_found ->
            now = System.os_time(:millisecond)
            label = attrs["label"] || attrs[:label]
            tags = attrs["tags"] || attrs[:tags] || []

            query!(Repo, """
            INSERT INTO kb_seeds (url, label, tags, created_at) VALUES (?, ?, ?, ?)
            """, [url, label, Jason.encode!(tags), now])

            fetch_by_url(url)
        end
    end
  end

  @spec delete(integer()) :: :ok | {:error, :not_found}
  def delete(id) when is_integer(id) do
    case query!(Repo, "SELECT 1 FROM kb_seeds WHERE id=?", [id]).rows do
      [_] ->
        query!(Repo, "DELETE FROM kb_seeds WHERE id=?", [id])
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Mark a seed as run. Status: 'ok' | 'error'. error_text optional."
  @spec mark_run(integer(), String.t(), String.t() | nil) :: :ok
  def mark_run(id, status, error \\ nil) when is_integer(id) and is_binary(status) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE kb_seeds SET last_run_at=?, last_status=?, last_error=? WHERE id=?
    """, [now, status, error, id])
    :ok
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp insert_missing(list) do
    now = System.os_time(:millisecond)

    inserted =
      Enum.reduce(list, 0, fn entry, acc ->
        url = String.trim(entry["url"] || "")

        cond do
          url == "" ->
            acc

          true ->
            case fetch_by_url(url) do
              {:ok, _}    -> acc
              :not_found ->
                tags = entry["tags"] || []
                label = entry["label"]
                query!(Repo, """
                INSERT OR IGNORE INTO kb_seeds (url, label, tags, created_at) VALUES (?, ?, ?, ?)
                """, [url, label, Jason.encode!(tags), now])
                acc + 1
            end
        end
      end)

    if inserted > 0, do: Logger.info("[Seeds] inserted #{inserted} preloaded URL(s)")
    :ok
  end

  defp fetch_by_url(url) do
    case query!(Repo, """
    SELECT id, url, label, tags, last_run_at, last_status, last_error, created_at
    FROM kb_seeds WHERE url=?
    """, [url]).rows do
      [row] -> {:ok, row_to_map(row)}
      _     -> :not_found
    end
  end

  defp row_to_map([id, url, label, tags_json, last_run_at, last_status, last_error, created_at]) do
    %{
      id: id,
      url: url,
      label: label,
      tags: decode_tags(tags_json),
      last_run_at: last_run_at,
      last_status: last_status,
      last_error: last_error,
      created_at: created_at
    }
  end

  defp decode_tags(nil), do: []
  defp decode_tags(""),  do: []
  defp decode_tags(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
