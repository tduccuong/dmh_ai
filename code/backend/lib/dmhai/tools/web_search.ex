# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.WebSearch do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Web.Search, as: WebSearchEngine

  @max_snippet_chars 500

  @impl true
  def name, do: "web_search"

  @impl true
  def description,
    do: "Live web search. EXPENSIVE — use only for time-sensitive or frequently-changing data."

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
  def execute(%{"query" => query}, _context) do
    {:ok, format_result(WebSearchEngine.search(query, [], :assistant))}
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
        content = Map.get(pages_by_url, s.url) || String.slice(s.snippet, 0, @max_snippet_chars)
        if content != "" do
          ["#{i}. #{s.title}\n#{s.url}\n#{content}"]
        else
          []
        end
      end)
      |> Enum.join("\n\n")

    if text == "", do: "No usable content found.", else: text
  end
end
