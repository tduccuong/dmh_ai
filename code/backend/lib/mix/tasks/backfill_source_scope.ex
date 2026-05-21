# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Mix.Tasks.Backfill.SourceScope do
  @moduledoc """
  One-off operator-run task — classifies every `kb_sources` row whose
  `source_scope` is NULL, persisting the JSON shape that the
  retrieval-time scope filter consumes.

  Pre-existing rows ingested before the source-scope architecture
  landed are untagged in the DB; the conservative auto-fetch
  predicate treats untagged as "include," so third-party platform
  docs (Bitrix24, HubSpot REST docs, etc.) leak into the model's
  context and poison reasoning. This task classifies them
  retroactively via `DmhAi.VectorDB.SourceScope.from_url/1`.

  Run:

      mix backfill.source_scope        # against the running app's DB

  Reports counts: scanned / tagged-from-url / left-untagged / errors.
  Idempotent — re-running skips rows that already have `source_scope`.
  """

  use Mix.Task
  import Ecto.Adapters.SQL, only: [query!: 3]

  @shortdoc "Backfill source_scope on kb_sources rows ingested before the scope architecture"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    alias DmhAi.{Repo, VectorDB.SourceScope}

    %{rows: rows} = query!(Repo,
      "SELECT id, source_kind, source_id FROM kb_sources WHERE source_scope IS NULL",
      [])

    IO.puts("[Backfill.SourceScope] scanning #{length(rows)} untagged rows")

    {tagged, untagged, errors} =
      Enum.reduce(rows, {0, 0, 0}, fn [id, source_kind, source_id], {t, u, e} ->
        try do
          scope_json =
            case source_kind do
              "url"    -> SourceScope.from_url(source_id)
              "file"   -> nil
              "folder" -> nil
              "text"   -> nil
              _        -> nil
            end

          case scope_json do
            nil ->
              {t, u + 1, e}

            blob when is_binary(blob) ->
              query!(Repo,
                "UPDATE kb_sources SET source_scope=? WHERE id=?",
                [blob, id])
              {t + 1, u, e}
          end
        rescue
          err ->
            IO.puts("  ! row id=#{id}: #{Exception.message(err)}")
            {t, u, e + 1}
        end
      end)

    IO.puts("[Backfill.SourceScope] done — tagged=#{tagged} left-untagged=#{untagged} errors=#{errors}")
  end
end
