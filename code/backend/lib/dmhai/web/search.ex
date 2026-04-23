# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Web.Search do
  @moduledoc """
  Shared web search implementation for Confidant and Assistant pipelines.

  Exposes:
    generate_search_queries/3  — one LLM call: decides whether to search, picks the
                                 SearXNG category, and generates optimised keyword queries.
                                 Returns `{:no_search} | {:search, category, queries}`.
    call_search_engine/3       — SearXNG search + page fetching via Web.Fetcher.
    search/4                   — generate_search_queries |> call_search_engine.
  """

  alias Dmhai.Agent.{AgentSettings, LLM}
  alias Dmhai.{DomainBlocker, Web.Fetcher}
  require Logger

  # ---------------------------------------------------------------------------
  # Prompts
  # ---------------------------------------------------------------------------

  # Confidant: decide YES/NO, pick category, generate queries — all in one call.
  @confidant_prompt """
  %{context_block}New message: "%{content}"

  Step 1 — Decide if a live web search is needed.
  Web search is EXPENSIVE. Say YES only when the user genuinely needs current or live information.

  Say NO when the user's intent is:
  - Summarising, translating, reformatting, or analysing content they provided (inline or via URL)
  - Writing help, coding questions you can answer, science, history, math, geography, well-known concepts
  - Anything you know confidently from training data

  Say YES when the user needs:
  - Breaking news, sports scores, stock/crypto prices, weather, live events, headlines
  - Technical docs, GitHub repos, library/framework versions, StackOverflow-style code questions
  - Statistics, laws, regulations, prices, or figures that change over time
  - A person's recent news, current job, or latest work
  - Anything you are unsure about or that could be outdated

  Judge the user's INTENT, not words embedded in content they want processed.
  Example: "translate this article: ...latest news..." → intent is translation → NO.

  Step 2 — If YES: pick the SearXNG category:
  - NEWS  : breaking news, sports, stock/crypto prices, weather, live events
  - IT    : code, programming, technical docs, GitHub, StackOverflow, library questions
  - GENERAL: everything else needing fresh or current data

  Step 3 — If YES: generate 1-4 keyword queries. Rules:
  - One query per language (dominant language first, then English if topic has English sources, then any explicitly relevant language)
  - Keyword-style only: NO sentences, NO filler words (für, mit, und, the, de, pour…)
  - 4-8 words per query; keep all proper names, brand names, product names exactly as-is
  - Add time context only where needed: "today" for live info, "this week"/"last week" for recent events, %{month} %{year} for general recency

  Output — exactly one of these two formats, no other text:

  SEARCH: NO

  or:

  SEARCH: YES
  CATEGORY: <NEWS|IT|GENERAL>
  LANG:xx keywords here
  LANG:xx more keywords
  """

  # Assistant: the worker has already decided to search — just pick category and optimise queries.
  @assistant_prompt """
  Task intent: "%{content}"

  Pick the SearXNG category and generate optimised keyword queries for this search intent.

  Category:
  - NEWS   : breaking news, sports, stock/crypto prices, weather, live events
  - IT     : code, programming, technical docs, GitHub, StackOverflow, library questions
  - GENERAL: everything else needing fresh or current data

  Queries — generate 1-3:
  - One query in the dominant language of the intent
  - One English query if the topic has significant English-language sources
  - One per additional explicitly relevant language
  - Keyword-style only: NO sentences, NO filler words
  - 4-8 words; keep all proper names, brand names, product names exactly as-is
  - Add time context only where needed: "today" for live, "this week" for recent, %{month} %{year} for general recency

  Output — no other text:
  CATEGORY: <NEWS|IT|GENERAL>
  LANG:xx keywords here
  LANG:xx more keywords
  """

  @max_raw_results 10

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  One LLM call that decides whether to search, picks the SearXNG category,
  and generates optimised keyword queries.

  Returns:
    * `{:no_search}`                      — search not needed (Confidant only)
    * `{:search, category, queries}`      — `category` is "news"|"it"|"news,general";
                                            `queries` is `[%{text, lang}]`
  """
  @spec generate_search_queries(String.t(), [String.t()], :confidant | :assistant) ::
          {:no_search} | {:search, String.t(), [%{text: String.t(), lang: String.t()}]}
  def generate_search_queries(content, recent_msgs \\ [], pipeline \\ :confidant) do
    model  = AgentSettings.web_search_model()
    prompt = build_prompt(content, recent_msgs, pipeline)

    trace = %{origin: "system", path: "Web.Search.generate_queries", role: "WebQueryPlanner", phase: "plan"}
    case LLM.call(model, [%{role: "user", content: prompt}], options: %{temperature: 0}, trace: trace) do
      {:ok, response} ->
        parse_response(response, pipeline, content)

      {:error, reason} ->
        Logger.warning("[Web.Search] generate_search_queries error: #{inspect(reason)}")
        if pipeline == :confidant do
          {:no_search}
        else
          {:search, "news,general", [%{text: content, lang: "auto"}]}
        end
    end
  end

  @doc """
  Run `queries` through SearXNG and fetch top-result pages via `Web.Fetcher`.

  Options:
    * `:reply_pid` — if set, sends `{:status, text}` messages for UI feedback.

  Returns `%{snippets: [map()], pages: [map()]}`.
  """
  @spec call_search_engine([map()], String.t(), keyword()) ::
          %{snippets: [map()], pages: [map()]}
  def call_search_engine(queries, category, opts \\ []) do
    reply_pid       = Keyword.get(opts, :reply_pid)
    progress_row_id = Keyword.get(opts, :progress_row_id)
    max_fetch = AgentSettings.web_search_max_fetch_pages()
    budget    = AgentSettings.web_search_fetch_content_budget()
    timeout   = AgentSettings.web_search_total_timeout_ms()

    search_tasks = Enum.map(queries, fn q ->
      Task.async(fn ->
        status_text = "🔍 #{q.text}"
        send_status(reply_pid, status_text)
        Dmhai.Agent.SessionProgress.append_sub_label(
          progress_row_id, "SearXNG(\"#{q.text}\")")
        do_search(q.text, q.lang, category)
      end)
    end)

    # yield_many so one stalled SearXNG query doesn't exit the whole
    # call. Matches the fetch-side pattern; keep the two in sync.
    all_results =
      search_tasks
      |> Task.yield_many(timeout)
      |> Enum.map(fn {task, res} ->
        case res do
          {:ok, value} -> value
          _ ->
            _ = Task.shutdown(task, :brutal_kill)
            []
        end
      end)
      |> Enum.reduce({[], MapSet.new()}, fn results, {acc, seen} ->
        Enum.reduce(results, {acc, seen}, fn r, {a, s} ->
          if MapSet.member?(s, r.url), do: {a, s}, else: {a ++ [r], MapSet.put(s, r.url)}
        end)
      end)
      |> elem(0)

    if all_results == [] do
      Logger.info("[Web.Search] no results for queries=#{inspect(Enum.map(queries, & &1.text))}")
      %{snippets: [], pages: []}
    else
      top = Enum.take(all_results, max_fetch)
      Logger.info("[Web.Search] got #{length(all_results)} results, fetching top #{length(top)}")

      fetch_tasks = Enum.map(top, fn result ->
        Task.async(fn ->
          send_status(reply_pid, "📄 #{String.slice(result.url, 0, 60)}")
          Dmhai.Agent.SessionProgress.append_sub_label(
            progress_row_id, "WebFetch(\"#{result.url}\")")
          fetch_page_content(result.url)
        end)
      end)

      # Use yield_many + shutdown instead of await_many so a single
      # stalled fetch (CMP/rate-limit/Jina stall) doesn't exit the whole
      # tool call. We keep whatever completed in time and kill the rest.
      pages =
        fetch_tasks
        |> Task.yield_many(timeout)
        |> Enum.map(fn {task, res} ->
          case res do
            {:ok, value} ->
              value
            _ ->
              _ = Task.shutdown(task, :brutal_kill)
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce({[], 0}, fn {url, title, text}, {acc, used} ->
          remaining = budget - used
          if remaining <= 0 do
            {acc, used}
          else
            trimmed = String.slice(text, 0, remaining)
            if String.length(trimmed) > 100 do
              {acc ++ [%{url: url, title: title, content: trimmed}], used + String.length(trimmed)}
            else
              {acc, used}
            end
          end
        end)
        |> elem(0)

      total_chars = Enum.reduce(pages, 0, fn p, acc -> acc + String.length(p.content) end)
      Logger.info("[Web.Search] snippets=#{length(top)} pages=#{length(pages)} chars=#{total_chars}")

      %{snippets: all_results, pages: pages}
    end
  end

  @doc """
  Full pipeline: generate queries (with search decision) → search → fetch pages.
  Returns `%{snippets: [], pages: []}` when search is not needed.
  """
  @spec search(String.t(), [String.t()], :confidant | :assistant, keyword()) ::
          :no_search | %{snippets: [map()], pages: [map()]}
  def search(content, recent_msgs \\ [], pipeline \\ :confidant, opts \\ []) do
    reply_pid = Keyword.get(opts, :reply_pid)
    if reply_pid, do: send(reply_pid, {:chunk, ""})

    case generate_search_queries(content, recent_msgs, pipeline) do
      {:no_search} ->
        Logger.info("[Web.Search] no search needed")
        :no_search

      {:search, category, queries} ->
        Dmhai.SysLog.log("[SEARCH] category=#{category} queries=#{inspect(Enum.map(queries, & &1.text))}")
        call_search_engine(queries, category, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_prompt(content, recent_msgs, pipeline) do
    date  = Date.utc_today()
    month = month_name(date.month)
    year  = Integer.to_string(date.year)

    template =
      case pipeline do
        :assistant -> @assistant_prompt
        _          -> @confidant_prompt
      end

    context_block =
      if pipeline == :confidant and recent_msgs != [] do
        lines = Enum.map_join(recent_msgs, "\n", fn m -> "- #{m}" end)
        "Recent user messages (oldest to newest):\n#{lines}\n\n"
      else
        ""
      end

    template
    |> String.replace("%{context_block}", context_block)
    |> String.replace("%{content}", content)
    |> String.replace("%{month}", month)
    |> String.replace("%{year}", year)
  end

  defp parse_response(response, :confidant, fallback) do
    lines = response |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)

    search_line = Enum.find(lines, fn l ->
      String.upcase(l) |> String.starts_with?("SEARCH:")
    end)

    decision =
      case search_line do
        nil  -> "NO"
        line -> line |> String.split(":") |> Enum.at(1, "") |> String.trim() |> String.upcase()
      end

    if decision == "YES" do
      {:search, extract_category(lines), extract_queries(lines, fallback)}
    else
      {:no_search}
    end
  end

  defp parse_response(response, :assistant, fallback) do
    lines = response |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)
    {:search, extract_category(lines), extract_queries(lines, fallback)}
  end

  defp extract_category(lines) do
    cat_line = Enum.find(lines, fn l ->
      String.upcase(l) |> String.starts_with?("CATEGORY:")
    end)

    case cat_line do
      nil -> "news,general"
      line ->
        val = line |> String.split(":") |> Enum.at(1, "") |> String.trim() |> String.upcase()
        case val do
          "NEWS" -> "news"
          "IT"   -> "it"
          _      -> "news,general"
        end
    end
  end

  defp extract_queries(lines, fallback) do
    queries =
      lines
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^LANG:([a-z]{2})\s+(.+)$/i, line) do
          [_, lang, kw] ->
            text =
              kw
              |> String.replace(~r/^[\d\.\-\*\s]+/, "")
              |> String.replace(~r/['"*]/, "")
              |> String.trim()
            if text != "", do: [%{text: text, lang: String.downcase(lang)}], else: []
          _ ->
            []
        end
      end)
      |> Enum.take(4)

    if queries == [] do
      Logger.info("[Web.Search] parse_queries fallback content=#{String.slice(fallback, 0, 60)}")
      [%{text: fallback, lang: "auto"}]
    else
      queries
    end
  end

  defp do_search(keywords, lang, category) do
    searxng_cats =
      case category do
        "news" -> "news"
        "it"   -> "it"
        _      -> "news,general"
      end

    params = %{
      q:          keywords,
      format:     "json",
      categories: searxng_cats,
      language:   lang,
      pageno:     1
    }

    url = AgentSettings.searxng_url() <> "/search?" <> URI.encode_query(params)

    try do
      case Req.get(url,
             headers:         [{"User-Agent", AgentSettings.http_user_agent()}],
             receive_timeout: AgentSettings.web_search_total_timeout_ms(),
             retry:           false,
             finch:           Dmhai.Finch
           ) do
        {:ok, %{status: 200, body: body}} ->
          data = if is_binary(body), do: Jason.decode!(body), else: body

          (data["results"] || [])
          |> Enum.filter(fn r -> not DomainBlocker.blocked?(r["url"] || "") end)
          |> Enum.uniq_by(fn r -> r["url"] end)
          |> Enum.take(@max_raw_results)
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

  defp fetch_page_content(url) do
    case Fetcher.fetch(url) do
      {:ok, %{content: content, title: title}} -> {url, title || "", content || ""}
      {:error, _}                              -> {url, "", ""}
    end
  end

  defp send_status(nil, _text), do: :ok
  defp send_status(pid, text),  do: send(pid, {:status, text})

  defp month_name(m) do
    Enum.at(
      ~w(January February March April May June July August September October November December),
      m - 1
    )
  end
end
