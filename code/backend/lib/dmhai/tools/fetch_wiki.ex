# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.FetchWiki do
  @moduledoc """
  Look up entries from the internal wiki — content the operator has
  curated via `/wiki` (URLs, files, folders, inline text). Framed as
  "wiki" rather than "knowledge" so the model doesn't conflate it with
  its own training corpus.

  Side effect: every successful fetch enqueues a background relearn
  job for each hit's source (see `specs/vector_kb.md` §Auto-relearn).
  Dedup'd by source_ref so concurrent users hitting the same source
  trigger one re-fetch.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.AgentSettings
  alias Dmhai.VectorDB
  alias Dmhai.VectorDB.{Embedder, Relearn}

  @impl true
  def name, do: "fetch_wiki"

  @impl true
  def description,
    do: "Look up entries from this user's internal wiki — content curated via /wiki (platform docs, internal procedures, snippets). Use for API specifics, domain facts, and learned techniques. NOT for chitchat or live data."

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
  def execute(%{"q" => q}, _ctx) when is_binary(q) and q != "" do
    with {:ok, vec}  <- Embedder.embed(q),
         {:ok, hits} <- VectorDB.search(:knowledge, q, vec, AgentSettings.kb_top_n(), :none) do
      Relearn.enqueue_for_hits(hits)
      {:ok, format(hits)}
    else
      {:error, reason} -> {:error, "fetch_wiki failed: #{inspect(reason)}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: q"}

  defp format(hits) do
    Enum.map(hits, fn h ->
      %{
        text:   h.chunk_text,
        source: "#{h.source_kind}:#{h.source_ref}",
        score:  Float.round(h.score, 4)
      }
    end)
  end
end
