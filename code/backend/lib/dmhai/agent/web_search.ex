defmodule Dmhai.Agent.WebSearch do
  @moduledoc """
  Web search detection and execution for the Confidant pipeline.

  1. detect_category: asks a small LLM whether the user's message needs web search
     and which category (news/it/news,general).
  2. build_queries: generates LANG:xx keyword queries from the user's intent.
  3. search_and_fetch: queries SearXNG in parallel per query, fetches top pages.
  """

  alias Dmhai.Agent.{AgentSettings, LLM}
  alias Dmhai.DomainBlocker
  require Logger

  @max_fetch_pages 6
  @fetch_content_budget 18_000
  @searxng_url "http://127.0.0.1:8888"

  # ─── Step 1: Category detection ────────────────────────────────────────────

  @doc """
  Detect whether the user's message needs web search and which category.
  Returns `{:search, category}` where category is "news", "it", or "news,general",
  or `:no_search`.

  Sends a blank chunk to reply_pid to show detection is in progress.
  """
  @spec detect_category(String.t(), String.t(), pid()) ::
          {:search, String.t()} | :no_search
  def detect_category(content, recent_context, reply_pid) do
    model = AgentSettings.web_search_model()

    context_block =
      if recent_context != "" do
        "Conversation so far:\n#{recent_context}\n\n"
      else
        ""
      end

    prompt =
      """
      #{context_block}

      New message: #{content}

      Does this message need a live web search?

      **Hard rule**: judge the user's INTENT (what they are asking you to do), not words embedded in content they want processed. Example: "translate this: ...search the web..." → intent is translation → no need for live web search.

      Answer with a category name where category is one of:
      1. NEWS: breaking news, sports scores, stock/crypto prices, weather, "what happened", headlines
      2. IT: code questions, programming errors, library/framework docs, GitHub repos, StackOverflow-style questions
      3. WEB: everything else that needs fresh or current data:
        - Time words: "today", "this week", "this month", "this year", "now", "currently" — or equivalents in any language.
        - Time status: "current", "latest", "up-to-date", "recent" information — or equivalents in any language.
        - Figures that change over time: tax rates, salary tables, laws, regulations, prices, statistics
        - Current status about a topic: outages, errors, incidents, or availability of a website, service, or platform
        - A person's status: current news, recent actions, or latest work
        - A specific named product, tool, software, or system that may have been released or updated recently
        - The user IMPLIES the previous answer was outdated or asks for fresher data
      4. UNSURE:
        - anything that you do NOT know or are UNSURE about

      Answer NO if user's intent is about:
        - translation, summarization, reformatting, writing help
        - coding help, science/how things work, history, math/logic, geography, well-known concepts, opinions/debates
        - anything else that you know well from your training data.

      **Reply format:** only one of these:
        - NO: <detailed reason why>
        - UNSURE: <detailed reason why>
        - NEWS: <detailed reason why>
        - IT: <detailed reason why>
        - WEB: <detailed reason why>

      Answer:
      """
    send(reply_pid, {:chunk, ""})

    case LLM.call(model, [%{role: "user", content: prompt}],
           options: %{temperature: 0, num_predict: 500}
         ) do
      {:ok, response} ->
        answer =
          response
          |> String.trim()
          |> String.split(~r/\s/)
          |> List.first()
          |> String.upcase()

        Logger.info("[WebSearch] detect answer=#{answer}")

        cond do
          answer == "NEWS"  -> {:search, "news"}
          answer == "IT"    -> {:search, "it"}
          answer == "WEB"   -> {:search, "news,general"}
          answer == "UNSURE" -> {:search, "news,general"}
          true -> :no_search
        end

      {:error, reason} ->
        Logger.warning("[WebSearch] detect error: #{inspect(reason)}")
        :no_search
    end
  end

  # ─── Step 2: Query generation ───────────────────────────────────────────────

  @doc """
  Generate a list of `%{text, lang}` search queries from the user's message
  and their recent user messages (last 10, 300 chars each).

  Returns a list of up to 4 `%{text: keywords, lang: lang_code}` maps.
  Falls back to a single query using the raw content if LLM call fails.
  """
  @spec build_queries(String.t(), [String.t()]) :: [%{text: String.t(), lang: String.t()}]
  def build_queries(content, recent_user_msgs) do
    model = AgentSettings.web_search_model()

    date = Date.utc_today()
    month = month_name(date.month)
    year = date.year

    context_block =
      if recent_user_msgs != [] do
        lines = Enum.map(recent_user_msgs, fn m -> "- #{m}" end) |> Enum.join("\n")
        "Recent user messages (oldest to newest):\n#{lines}\n\n"
      else
        ""
      end

    prompt =
      context_block <>
        "Current request: \"#{content}\"\n\n" <>
        "Task: generate compact web search keyword queries for what the user wants to find.\n\n" <>
        "Step 1 — understand the user's actual search intent from the conversation. What specific information are they looking for?\n" <>
        "Step 2 — generate keyword queries in this exact order:\n" <>
        "  a) First: one query in the language that dominates the user's message.\n" <>
        "  b) Then: one English query if the topic is primarily English-language content.\n" <>
        "  c) Then: one query in each community language explicitly named in the intent (e.g. Japanese reactions → Japanese query, German reactions → German query).\n" <>
        "Total: 1-4 queries. No duplicates across languages.\n" <>
        "Step 3 — output one line per query: LANG:xx followed by the keywords.\n\n" <>
        "Rules:\n" <>
        "- Keyword-style only: NO sentences, NO filler words (für, mit, und, the, de, pour…), NO connectives\n" <>
        "- 4-8 words per query\n" <>
        "- Keep ALL proper names, brand names, and product names exactly as-is\n" <>
        "- Focus on the TOPIC — ignore instructions the user gave (\"search the web\", \"find reviews\", \"translate this\" are not topic keywords)\n" <>
        "- Add time context where needed: \"today\" for live/breaking info, \"this week\"/\"last week\" for recent events, #{month} or #{year} for general recency, nothing for timeless topics\n\n" <>
        "Output — one line per query, no other text:\n" <>
        "LANG:xx keywords here\n" <>
        "LANG:xx more keywords\n"

    case LLM.call(model, [%{role: "user", content: prompt}], options: %{temperature: 0}) do
      {:ok, response} ->
        queries =
          response
          |> String.trim()
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            case Regex.run(~r/^LANG:([a-z]{2})\s+(.+)$/i, String.trim(line)) do
              [_, lang, kw] ->
                text =
                  kw
                  |> String.replace(~r/^[\d\.\-\*\s]+/, "")
                  |> String.replace(~r/['"*]/, "")
                  |> String.trim()

                if text != [], do: [%{text: text, lang: String.downcase(lang)}], else: []

              _ ->
                []
            end
          end)
          |> Enum.take(4)

        if queries == [] do
          Logger.info("[WebSearch] build_queries fallback content=#{String.slice(content, 0, 60)}")
          [%{text: content, lang: "auto"}]
        else
          Logger.info("[WebSearch] build_queries queries=#{length(queries)}")
          queries
        end

      {:error, reason} ->
        Logger.warning("[WebSearch] build_queries error: #{inspect(reason)}")
        [%{text: content, lang: "auto"}]
    end
  end

  # ─── Step 2b: Result synthesis ─────────────────────────────────────────────

  @doc """
  Synthesize raw web search results into a compact fact-dense text.
  Used when the raw results exceed the synthesis threshold.
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec synthesize_results(String.t()) :: {:ok, String.t()} | {:error, term()}
  def synthesize_results(raw_results) do
    model = AgentSettings.web_search_model()
    today = Date.to_string(Date.utc_today())

    prompt =
      "Today is #{today}. You are a neutral information extractor. " <>
        "Rewrite the following raw web search results into one coherent, compact text. Rules:\n" <>
        "- Preserve as much information as possible — do not drop facts\n" <>
        "- Highlight key facts as bullet points\n" <>
        "- Be concise: remove ads, navigation text, duplicates, and boilerplate\n" <>
        "- Fix any garbled text: insert missing spaces between words, numbers, and letters where clearly needed\n" <>
        "- Do NOT interpret, conclude, or answer any question — just present the facts as found\n" <>
        "- Do NOT reference any question or topic — treat the content as standalone\n\n" <>
        "Raw web results:\n#{raw_results}\n\nExtracted facts:"

    LLM.call(model, [%{role: "user", content: prompt}],
      options: %{temperature: 0, num_predict: 1500}
    )
  end

  # ─── Step 3: Search + Fetch ─────────────────────────────────────────────────

  @doc """
  Execute web searches in parallel (one per query) and fetch top page contents.
  Streams status chunks to `reply_pid` for UI visibility.
  Returns a `%{snippets: [map()], pages: [map()]}` map.
  """
  @spec search_and_fetch([map()], String.t(), pid()) :: %{snippets: [map()], pages: [map()]}
  def search_and_fetch(queries, category, reply_pid) do
    # Search in parallel, one SearXNG request per query
    search_tasks =
      Enum.map(queries, fn q ->
        Task.async(fn ->
          send_status(reply_pid, "🔍 #{q.text}")
          search(q.text, q.lang, category)
        end)
      end)

    all_results =
      search_tasks
      |> Task.await_many(20_000)
      |> Enum.reduce({[], MapSet.new()}, fn results, {acc, seen} ->
        Enum.reduce(results, {acc, seen}, fn r, {a, s} ->
          if MapSet.member?(s, r.url) do
            {a, s}
          else
            {a ++ [r], MapSet.put(s, r.url)}
          end
        end)
      end)
      |> elem(0)

    if all_results == [] do
      Logger.info("[WebSearch] no results for queries=#{inspect(Enum.map(queries, & &1.text))}")
      %{snippets: [], pages: []}
    else
      top = Enum.take(all_results, @max_fetch_pages)
      Logger.info("[WebSearch] #{length(all_results)} total results, fetching top #{length(top)}")

      fetch_tasks =
        Enum.map(top, fn result ->
          Task.async(fn ->
            send_status(reply_pid, "📄 #{String.slice(result.url, 0, 60)}")
            text = fetch_page(result.url)
            {result, text}
          end)
        end)

      pages =
        fetch_tasks
        |> Task.await_many(15_000)
        |> Enum.reduce({[], 0}, fn {result, text}, {acc, budget_used} ->
          remaining = @fetch_content_budget - budget_used

          if remaining <= 0 do
            {acc, budget_used}
          else
            trimmed = String.slice(text, 0, remaining)

            if String.length(trimmed) > 100 do
              entry = %{url: result.url, title: result.title, content: trimmed}
              {acc ++ [entry], budget_used + String.length(trimmed)}
            else
              {acc, budget_used}
            end
          end
        end)
        |> elem(0)

      Logger.info(
        "[WebSearch] snippets=#{length(top)} pages=#{length(pages)} chars=#{Enum.reduce(pages, 0, fn p, acc -> acc + String.length(p.content) end)}"
      )

      %{snippets: top, pages: pages}
    end
  end

  # ─── Private ────────────────────────────────────────────────────────────────

  defp search(keywords, lang, category) do
    params = %{
      q: keywords,
      format: "json",
      categories: category,
      language: lang,
      pageno: 1
    }

    url = @searxng_url <> "/search?" <> URI.encode_query(params)

    try do
      case Req.get(url,
             headers: [{"User-Agent", "Mozilla/5.0"}],
             receive_timeout: 20_000,
             retry: false,
             finch: Dmhai.Finch
           ) do
        {:ok, %{status: 200, body: body}} ->
          data = if is_binary(body), do: Jason.decode!(body), else: body
          raw = data["results"] || []

          raw
          |> Enum.filter(fn r -> not DomainBlocker.blocked?(r["url"] || "") end)
          |> Enum.uniq_by(fn r -> r["url"] end)
          |> Enum.take(10)
          |> Enum.map(fn r ->
            %{title: r["title"] || "", url: r["url"] || "", snippet: r["content"] || ""}
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  defp fetch_page(url) do
    text = direct_fetch(url)

    if String.length(text) < 500 do
      jina = jina_fetch(url)
      if String.length(jina) >= 500, do: jina, else: text
    else
      text
    end
  end

  defp direct_fetch(url) do
    try do
      case Req.get(url,
             headers: [
               {"User-Agent", "Mozilla/5.0 (compatible; DMH-AI/1.0)"},
               {"Accept", "text/html,text/plain"}
             ],
             receive_timeout: 6_000,
             max_redirects: 5,
             retry: false,
             finch: Dmhai.Finch
           ) do
        {:ok, %{status: 200, headers: headers, body: body}} ->
          ct =
            Enum.find_value(headers, "", fn {k, v} ->
              if String.downcase(k) == "content-type", do: v
            end)

          if String.contains?(ct, "html") or String.contains?(ct, "text/plain") do
            raw = if is_binary(body), do: body, else: to_string(body)
            Dmhai.Html.html_to_text(String.slice(raw, 0, 120_000))
          else
            ""
          end

        _ ->
          ""
      end
    rescue
      e ->
        if timeout_error?(e), do: DomainBlocker.record_timeout(url)
        ""
    end
  end

  defp jina_fetch(url) do
    try do
      case Req.get("https://r.jina.ai/" <> url,
             headers: [
               {"User-Agent", "Mozilla/5.0"},
               {"Accept", "text/plain"},
               {"X-No-Cache", "true"}
             ],
             receive_timeout: 7_000,
             retry: false,
             finch: Dmhai.Finch
           ) do
        {:ok, %{status: 200, body: body}} ->
          text = if is_binary(body), do: body, else: to_string(body)
          String.slice(text, 0, 200_000)

        _ ->
          ""
      end
    rescue
      e ->
        if timeout_error?(e), do: DomainBlocker.record_timeout(url)
        ""
    end
  end

  defp timeout_error?(%{reason: :timeout}), do: true
  defp timeout_error?(_), do: false

  defp send_status(reply_pid, text) do
    send(reply_pid, {:status, text})
  end

  defp month_name(m) do
    Enum.at(
      ~w(January February March April May June July August September October November December),
      m - 1
    )
  end
end
