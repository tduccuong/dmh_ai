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
          q: %{
            type: "string",
            description:
              "Keywords or a short natural-language phrase. Be SPECIFIC: " <>
                "include the subject domain (which platform / product / " <>
                "topic), not bare jargon. A generic query like \"workflow " <>
                "output\" returns hits from every product the org has " <>
                "ever indexed; \"DMH-AI workflow output node\" or " <>
                "\"HubSpot workflow output step\" narrows to what you " <>
                "actually want."
          },
          scope: %{
            type: "object",
            description:
              "Optional retrieval-scope filter. Restricts hits to KB " <>
                "sources matching the given platform / category. Use when " <>
                "you want to exclude unrelated indexed material.",
            properties: %{
              platforms_in: %{
                type: "array",
                items: %{type: "string"},
                description:
                  "Whitelist: only hits whose source's `platform` is in " <>
                    "this list pass. Use the connector slug " <>
                    "(`google_workspace`, `hubspot`, `m365`, etc.) or " <>
                    "the special slug `dmh_ai` for the runtime's own " <>
                    "docs / saved workflows."
              },
              platforms_not_in: %{
                type: "array",
                items: %{type: "string"},
                description:
                  "Blacklist: hits from these platforms are excluded."
              },
              categories_in: %{
                type: "array",
                items: %{type: "string"},
                description:
                  "Whitelist categories (`api-docs` / `sop` / `policy` / " <>
                    "`workflow` / `spec` / `general`)."
              },
              include_untagged: %{
                type: "boolean",
                description:
                  "Default true. When false, only tagged sources qualify."
              }
            }
          }
        }
      }
    }
  end

  @impl true
  def execute(%{"q" => q} = args, ctx) when is_binary(q) and q != "" do
    org_id = DmhAi.Orgs.for_user(ctx[:user_id] || ctx["user_id"])
    filter = build_filter(org_id, args["scope"])

    with {:ok, vec}  <- Embedder.embed(q),
         {:ok, hits} <- VectorDB.search(:knowledge, q, vec, AgentSettings.kb_top_n(), filter) do
      enqueue_bg_refresh(org_id, hits)
      Relearn.enqueue_for_hits(hits)
      {:ok, format(hits)}
    else
      {:error, reason} -> {:error, "fetch_index failed: #{inspect(reason)}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: q"}

  # Convert the model-supplied `scope` arg into the backend's filter
  # shape. Absent / malformed `scope` falls back to plain org-only.
  defp build_filter(org_id, nil), do: {:org, org_id}
  defp build_filter(org_id, scope) when is_map(scope) do
    pred =
      [:platforms_in, :platforms_not_in, :categories_in, :include_untagged]
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.get(scope, Atom.to_string(key)) do
          nil -> acc
          v   -> Map.put(acc, key, v)
        end
      end)

    if map_size(pred) == 0,
      do: {:org, org_id},
      else: {:org, org_id, pred}
  end

  defp build_filter(org_id, _), do: {:org, org_id}

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
