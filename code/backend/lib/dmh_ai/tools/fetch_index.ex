# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.FetchIndex do
  @moduledoc """
  Look up entries from the internal index — content the operator has
  curated via `/index` (URLs, files, folders, inline text). Framed
  to the model as a project-specific reference rather than as
  "knowledge", so it doesn't conflate index hits with its own
  training corpus.

  Side effect: every successful fetch enqueues a background relearn
  job for each hit's source (see `specs/vector_kb.md` §Auto-relearn).
  Dedup'd by source_ref so concurrent users hitting the same source
  trigger one re-fetch.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.{Embedder, Relearn}

  @impl true
  def name, do: "fetch_index"

  @impl true
  def description,
    do: "Look up entries from this user's internal index — content curated via /index (platform docs, internal procedures, snippets). Use for API specifics, domain facts, and learned techniques. NOT for chitchat or live data."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        required: ["q"],
        properties: %{
          q: %{type: "string", description: "Keywords or a short natural-language phrase."}
        }
      }
    }
  end

  @impl true
  def execute(%{"q" => q}, ctx) when is_binary(q) and q != "" do
    org_id = DmhAi.Orgs.for_user(ctx[:user_id] || ctx["user_id"])

    with {:ok, vec}  <- Embedder.embed(q),
         {:ok, hits} <- VectorDB.search(:knowledge, q, vec, AgentSettings.kb_top_n(), {:org, org_id}) do
      enqueue_bg_refresh(org_id, hits)
      Relearn.enqueue_for_hits(hits)
      {:ok, format(hits)}
    else
      {:error, reason} -> {:error, "fetch_index failed: #{inspect(reason)}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: q"}

  # Per Primitive 0.2: every fetch_index call enqueues one
  # `BgRefreshWorker` per distinct `source_id` whose chunks were
  # returned. Worker debounces via
  # `AgentSettings.bg_refresh_min_interval_s/0` so a query storm
  # on a hot source collapses to one upstream HEAD-check per window.
  defp enqueue_bg_refresh(org_id, hits) do
    hits
    |> Enum.map(& &1.source_id)
    |> Enum.uniq()
    |> Enum.each(fn source_id ->
      DmhAi.Ingest.BgRefreshWorker.enqueue(org_id, source_id)
    end)
  end

  defp format(hits) do
    Enum.map(hits, fn h ->
      %{
        text:   h.chunk_text,
        source: "#{h.source_kind}:#{h.source_id}",
        score:  Float.round(h.score, 4)
      }
    end)
  end
end
