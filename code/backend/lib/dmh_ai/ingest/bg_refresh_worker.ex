# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Ingest.BgRefreshWorker do
  @moduledoc """
  Background KB-source refresh worker per Primitive 0.2.

  Triggered implicitly by `Tools.FetchIndex` — one worker per
  distinct `source_id` whose chunks were returned. Reads
  `kb_sources.last_check_at`; if checked within
  `AgentSettings.bg_refresh_min_interval_s/0` (default 600 s),
  the worker is a no-op. Otherwise it re-fetches the upstream
  bytes and calls `Ingest.upsert_kb_source/2` — SKIP or REPLACE
  per content hash.

  Errors (404, 401, network) DO NOT remove chunks; they just set
  `last_check_failed_at` + `last_check_error` so an admin can
  triage. Removal stays admin-only (Primitive 0.2 guarantee iii).
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Ingest
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Enqueue a refresh under the `DmhAi.Ingest.BgRefreshSupervisor`. Fire
  and forget. Returns `{:ok, pid}` on enqueue.
  """
  @spec enqueue(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def enqueue(org_id, source_id) when is_binary(org_id) and is_binary(source_id) do
    Task.Supervisor.start_child(DmhAi.Ingest.BgRefreshSupervisor, fn ->
      run(org_id, source_id)
    end)
  end

  @doc """
  Run synchronously (useful in tests). Returns `:skipped`, `:refreshed`,
  `:failed_upstream`, `:not_found`, or `{:error, reason}`.
  """
  @spec run(String.t(), String.t()) ::
          :skipped | :refreshed | :failed_upstream | :not_found | {:error, term()}
  def run(org_id, source_id) do
    case load_source(org_id, source_id) do
      nil ->
        :not_found

      %{last_check_at: last_check, parent_last_check_at: parent_check,
        source_kind: kind, raw_ref: ref, title: title} ->
        debounce_s = AgentSettings.bg_refresh_min_interval_s()
        now_ms = System.os_time(:millisecond)

        # Two-level debounce: skip if either THIS source OR ITS
        # parent was checked within the window. Parent-side check
        # collapses fan-out — when a fetch_index turn hits N
        # children of one crawled site, only the first one (or the
        # parent itself, whichever fires first) actually re-fetches;
        # the rest are no-ops until the window expires. Sources
        # without a parent (the seed URL itself, file/folder/text
        # sources) fall back to the single-level check via the
        # `parent_check = nil` branch.
        if recent?(last_check, now_ms, debounce_s) or
             recent?(parent_check, now_ms, debounce_s) do
          :skipped
        else
          do_refresh(org_id, source_id, kind, ref, title, now_ms)
        end
    end
  rescue
    e ->
      Logger.warning("[BgRefresh] crash #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp load_source(org_id, source_id) do
    # LEFT JOIN onto the parent row so we get `parent_last_check_at`
    # in one round-trip. Sources without a parent get NULL.
    case query!(Repo, """
    SELECT child.source_kind, child.source_id, child.title, child.last_check_at,
           parent.last_check_at
    FROM   kb_sources child
    LEFT JOIN kb_sources parent
      ON parent.org_id = child.org_id
     AND parent.source_id = child.parent_source_id
    WHERE  child.org_id=? AND child.source_id=?
    """, [org_id, source_id]).rows do
      [[kind, raw_ref, title, last_check, parent_check]] ->
        %{source_kind: kind, raw_ref: raw_ref, title: title,
          last_check_at: last_check, parent_last_check_at: parent_check}

      _ ->
        nil
    end
  end

  defp recent?(nil, _now, _debounce_s), do: false

  defp recent?(last_check, now_ms, debounce_s) when is_integer(last_check) do
    now_ms - last_check < debounce_s * 1_000
  end

  defp do_refresh(org_id, source_id, "url", url, title, _now_ms) do
    case DmhAi.Web.Fetcher.fetch(url, extractor: :kb, max_chars: 200_000) do
      {:ok, %{content: body}} when is_binary(body) and body != "" ->
        attrs = %{
          scope:       :knowledge,
          org_id:      org_id,
          source_kind: "url",
          source_ref:  url,
          source_id:   source_id,
          title:       title
        }

        case Ingest.upsert_kb_source(attrs, body) do
          {:ok, %{action: :skipped}} ->
            stamp_success(org_id, source_id)
            :skipped

          {:ok, %{action: action}} when action in [:inserted, :replaced] ->
            stamp_success(org_id, source_id)
            :refreshed

          {:error, _reason} ->
            stamp_failure(org_id, source_id, "ingest_error")
            :failed_upstream
        end

      {:error, reason} ->
        stamp_failure(org_id, source_id, "fetch_#{inspect_short(reason)}")
        :failed_upstream

      _ ->
        stamp_failure(org_id, source_id, "fetch_no_content")
        :failed_upstream
    end
  end

  # File / folder / text / connector — re-fetch path varies. For
  # Phase B we skip non-URL sources in BG refresh (they don't usually
  # have a stable upstream to re-pull). Stamp the check timestamp
  # so debounce still applies.
  defp do_refresh(org_id, source_id, _other_kind, _ref, _title, now_ms) do
    query!(Repo,
      "UPDATE kb_sources SET last_check_at=? WHERE org_id=? AND source_id=?",
      [now_ms, org_id, source_id])
    :skipped
  end

  defp stamp_success(org_id, source_id) do
    now_ms = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE kb_sources
       SET last_check_at=?, last_check_failed_at=NULL, last_check_error=NULL
     WHERE org_id=? AND source_id=?
    """, [now_ms, org_id, source_id])
  end

  defp stamp_failure(org_id, source_id, reason) do
    now_ms = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE kb_sources
       SET last_check_at=?, last_check_failed_at=?, last_check_error=?
     WHERE org_id=? AND source_id=?
    """, [now_ms, now_ms, reason, org_id, source_id])
  end

  defp inspect_short(v), do: v |> inspect() |> String.slice(0, 40)
end
