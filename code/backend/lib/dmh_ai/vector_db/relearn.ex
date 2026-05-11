# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.Relearn do
  @moduledoc """
  Background re-fetch supervisor for stale KB sources. Trigger:
  `enqueue_for_hits/1` is called from `fetch_index` after every
  successful query, with the list of hits. For each unique
  `source_ref`, we `INSERT OR IGNORE` into `kb_relearn_jobs`
  (cross-user / cross-process dedup) and start a Task under the
  DynamicSupervisor — capped at `kb_relearn_concurrency`.

  Inline-text sources (`source_kind == "text"`) are skipped — there's
  no upstream to re-fetch.

  The actual re-fetch dispatch (URL crawl / file re-extract) lives in
  the runtime command pipelines (`specs/commands.md`). This module
  owns enqueue + dedup + cap; the worker function it invokes is
  pluggable via `:dmh_ai, :kb_relearn_worker` config (default: a
  no-op stub until the pipeline lands).
  """

  use DynamicSupervisor
  alias DmhAi.Repo
  alias DmhAi.Agent.AgentSettings
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc false
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Enqueue background relearn jobs for every unique source in `hits`
  (skipping `text` kind). Returns immediately — fire-and-forget.
  """
  @spec enqueue_for_hits([map()]) :: :ok
  def enqueue_for_hits(hits) when is_list(hits) do
    hits
    |> Enum.reject(&(&1[:source_kind] == "text"))
    |> Enum.uniq_by(&{&1[:source_kind], &1[:source_ref]})
    |> Enum.each(&try_enqueue/1)

    :ok
  end

  @doc """
  Process a single relearn job synchronously (test hook). Production
  callers go through `try_enqueue/1` which dispatches via the
  supervisor.
  """
  @spec run_now(map()) :: :ok | {:error, term()}
  def run_now(%{source_kind: kind, source_ref: ref}) do
    worker = Application.get_env(:dmh_ai, :kb_relearn_worker, &noop_worker/2)
    result = worker.(kind, ref)
    cleanup(ref)
    result
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp try_enqueue(hit) do
    kind = hit[:source_kind]
    ref  = hit[:source_ref]
    now  = System.os_time(:millisecond)

    # INSERT OR IGNORE — wins the race against any other process
    # already enqueueing the same source. If returning_changes shows
    # 0 rows, someone got there first; we silently skip.
    %{num_rows: inserted} =
      query!(Repo, """
      INSERT OR IGNORE INTO kb_relearn_jobs (source_ref, source_kind, enqueued_at)
      VALUES (?, ?, ?)
      """, [ref, kind, now])

    if inserted > 0 and under_concurrency_cap?() do
      DynamicSupervisor.start_child(__MODULE__, {Task, fn -> run_now(hit) end})
    else
      # Either dedup'd OR over the cap. Job stays in the table; the
      # next user query that hits the same source will retry, and the
      # next available supervisor slot picks it up.
      :ok
    end
  end

  defp under_concurrency_cap? do
    %{active: active} = DynamicSupervisor.count_children(__MODULE__)
    active < AgentSettings.kb_relearn_concurrency()
  rescue
    _ -> true
  end

  defp cleanup(ref) do
    query!(Repo, "DELETE FROM kb_relearn_jobs WHERE source_ref=?", [ref])
    :ok
  end

  # Default worker — re-fetches a stale source via the same pipeline
  # `/index` uses for the matching kind. Inline-text sources (sha256
  # source_ref) are filtered out at enqueue time; we still defensively
  # skip them here. The KB ingest is global (`:knowledge` scope, no
  # user_id) — relearn doesn't post chat messages because there's no
  # session/user context tied to the original /index.
  defp noop_worker(kind, ref) do
    Logger.info("[Relearn] worker re-fetching #{kind}:#{ref}")

    case kind do
      "url" ->
        do_relearn_url(ref)

      "file" ->
        do_relearn_file(ref)

      "folder" ->
        # Folder sources are stored per-file; a hit's source_kind would
        # never be 'folder'. Defensive no-op.
        :ok

      "text" ->
        # Skipped at enqueue; defensive no-op here.
        :ok

      _ ->
        Logger.warning("[Relearn] unknown source_kind=#{kind}")
        :ok
    end
  end

  defp do_relearn_url(url) do
    case DmhAi.Web.Fetcher.fetch(url, extractor: :kb, max_chars: 200_000) do
      {:ok, %{title: title, content: text}} when is_binary(text) and text != "" ->
        DmhAi.VectorDB.ingest(%{
          scope:       :knowledge,
          user_id:     nil,
          source_kind: "url",
          source_ref:  url,
          title:       title || url
        }, text)
        :ok

      {:error, reason} ->
        Logger.info("[Relearn] url=#{url} fetch failed: #{inspect(reason, limit: 80)}")
        :ok

      _ ->
        :ok
    end
  end

  defp do_relearn_file(path) do
    case DmhAi.Tools.ExtractContent.execute(%{"path" => path}, %{}) do
      {:ok, body} when is_binary(body) and body != "" ->
        DmhAi.VectorDB.ingest(%{
          scope:       :knowledge,
          user_id:     nil,
          source_kind: "file",
          source_ref:  path,
          title:       Path.basename(path)
        }, body)
        :ok

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.info("[Relearn] file=#{path} crash: #{Exception.message(e)}")
      :ok
  end
end
