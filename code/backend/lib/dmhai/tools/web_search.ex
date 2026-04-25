# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.WebSearch do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Web.Search, as: WebSearchEngine

  @max_snippet_chars 500

  # Source of truth for the "when to call web_search" guidance shown to the
  # Assistant-mode model via the tool schema's description. The Confidant
  # pipeline has its own pre-call classifier prompt in Dmhai.Web.Search —
  # different framing ("Say YES/NO"), same underlying criteria; the two can
  # be DRYed later if they drift.
  @tool_description """
  Performs the search AND returns the content of the top results as a numbered list:

      N. <title>
      <url>
      [fetched]
      <content>

  `[fetched]` means the content is here in full. Do NOT call `web_fetch` on any URL already in your recent `web_search` result — nothing more to retrieve. Compile your answer from the returned content and cite source URLs alongside each claim.

  **Call `web_search` for**: current / changing information — news, prices, weather, live data, statistics, regulations, a person's recent work, library versions, anything that could have changed since your training cutoff. If the ask is time-sensitive or names something whose state could be newer than your training data, search rather than answer from memory.

  Any other use will be REJECTED.
  """

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: @tool_description

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Your search intent in plain language or keywords."
          }
        },
        required: ["query"]
      }
    }
  end

  @impl true
  def execute(%{"query" => query}, context) do
    opts = [progress_row_id: Map.get(context || %{}, :progress_row_id)]
    {:ok, format_result(WebSearchEngine.search(query, [], :assistant, opts))}
  end

  def execute(_, _), do: {:error, "Missing required argument: query"}

  # ── private ──────────────────────────────────────────────────────────────

  defp format_result(%{snippets: [], pages: []}), do: "No results found."

  defp format_result(%{snippets: snippets, pages: pages}) do
    pages_by_url = Map.new(pages, fn p -> {p.url, p.content} end)

    text =
      snippets
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {s, i} ->
        # Content is either the full fetched page text OR the SearXNG
        # snippet if the fetch didn't yield anything usable. Either way
        # it's all we have for this URL — tag every entry `[fetched]`
        # so the model doesn't try web_fetch on any of them.
        content = Map.get(pages_by_url, s.url) || String.slice(s.snippet, 0, @max_snippet_chars)
        if content != "" do
          ["#{i}. #{s.title}\n#{s.url}\n[fetched]\n#{content}"]
        else
          []
        end
      end)
      |> Enum.join("\n\n")

    if text == "", do: "No usable content found.", else: text
  end
end
