# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.WebSearch do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.AgentSettings

  @max_results 8
  @max_snippet_chars 500

  @impl true
  def name, do: "web_search"

  @impl true
  def description,
    do:
      "Search the web using SearXNG. Returns titles, URLs, and snippets for the top results. " <>
        "Use web_fetch to read the full content of any result URL."

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
            description: "Search keywords (4-8 words, no filler words)."
          },
          category: %{
            type: "string",
            enum: ["general", "news", "it"],
            description:
              "Search category. Use 'news' for breaking news/prices/scores, " <>
                "'it' for code/programming/docs, 'general' for everything else. Defaults to 'news,general'."
          }
        },
        required: ["query"]
      }
    }
  end

  @impl true
  def execute(%{"query" => query} = args, _context) do
    category = Map.get(args, "category", "news,general")

    searxng_cats =
      case category do
        "news"        -> "news"
        "it"          -> "it"
        "news,general" -> "news,general"
        _             -> "news,general"
      end

    params = %{
      q:          query,
      format:     "json",
      categories: searxng_cats,
      pageno:     1
    }

    url = AgentSettings.searxng_url() <> "/search?" <> URI.encode_query(params)

    try do
      case Req.get(url,
             headers: [{"User-Agent", AgentSettings.http_user_agent()}],
             receive_timeout: AgentSettings.web_search_total_timeout_ms(),
             retry: false,
             finch: Dmhai.Finch
           ) do
        {:ok, %{status: 200, body: body}} ->
          data = if is_binary(body), do: Jason.decode!(body), else: body
          results = data["results"] || []

          filtered =
            results
            |> Enum.reject(fn r -> Dmhai.DomainBlocker.blocked?(r["url"] || "") end)
            |> Enum.uniq_by(fn r -> r["url"] end)
            |> Enum.take(@max_results)

          if filtered == [] do
            {:ok, "No results found for: #{query}"}
          else
            text =
              filtered
              |> Enum.with_index(1)
              |> Enum.map_join("\n\n", fn {r, i} ->
                title   = r["title"] || ""
                link    = r["url"] || ""
                snippet = r["content"] || "" |> String.slice(0, @max_snippet_chars)
                "#{i}. #{title}\n#{link}\n#{snippet}"
              end)

            {:ok, text}
          end

        {:ok, %{status: status}} ->
          {:error, "SearXNG returned HTTP #{status}"}

        {:error, reason} ->
          {:error, "Search failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "Search error: #{Exception.message(e)}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: query"}
end
