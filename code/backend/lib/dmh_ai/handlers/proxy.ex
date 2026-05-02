# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Proxy do
  import Plug.Conn
  alias DmhAi.Repo
  alias DmhAi.DomainBlocker
  alias DmhAi.Util.Html
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @user_agent "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0"

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # GET /local-api/* (no auth required)
  def get_local_api(conn, sub) do
    endpoint = get_local_endpoint()

    case proxy_get(endpoint, "/api/#{sub}", [], timeout: 10_000) do
      {:ok, status, headers, body} ->
        ct = Enum.find_value(headers, "application/json", fn {k, v} ->
          if String.downcase(k) == "content-type", do: v
        end)

        conn
        |> put_resp_content_type(ct)
        |> send_resp(status, body)

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  # GET /admin/settings
  def get_admin_settings(conn, _user) do
    result = query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"])

    data =
      case result.rows do
        [[v] | _] -> Jason.decode!(v || "{}")
        _ -> %{}
      end

    payload =
      data
      |> Map.put("systemModels",   DmhAi.Agent.AgentSettings.system_model_names())
      |> Map.put("modelDefaults",  DmhAi.Agent.AgentSettings.model_defaults())

    json(conn, 200, payload)
  end

  # GET /model-labels
  def get_model_labels(conn, _user) do
    result = query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"])

    model_labels =
      case result.rows do
        [[v] | _] ->
          data = Jason.decode!(v || "{}")
          data["modelLabels"] || %{}

        _ ->
          %{}
      end

    json(conn, 200, %{modelLabels: model_labels})
  end

  # GET /admin/test-endpoint (admin only)
  def get_test_endpoint(conn, user) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      params = URI.decode_query(conn.query_string)
      url = String.trim(params["url"] || "") |> String.trim_trailing("/")

      if url == "" do
        json(conn, 400, %{error: "Missing url"})
      else
        case proxy_get(url, "/api/tags", [], timeout: 5_000) do
          {:ok, 200, _headers, body} ->
            json(conn, 200, Jason.decode!(body))

          {:ok, status, _headers, _body} ->
            json(conn, 502, %{error: "Ollama returned #{status}"})

          {:error, reason} ->
            json(conn, 502, %{error: inspect(reason)})
        end
      end
    end
  end

  # GET /cloud-api/* (auth required)
  def get_cloud_api(conn, _user, sub) do
    cloud_key = get_req_header(conn, "x-cloud-key") |> List.first() |> then(&(if &1, do: String.trim(&1), else: ""))

    case proxy_get("https://ollama.com", "/api/#{sub}",
           [{"Authorization", "Bearer #{cloud_key}"}],
           timeout: 10_000
         ) do
      {:ok, status, headers, body} ->
        ct = Enum.find_value(headers, "application/json", fn {k, v} ->
          if String.downcase(k) == "content-type", do: v
        end)

        conn
        |> put_resp_content_type(ct)
        |> send_resp(status, body)

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  # GET /search?q=...&engine=...&lang=...&category=...
  def get_search(conn) do
    params = URI.decode_query(conn.query_string)
    q = params["q"] || ""
    engine = params["engine"] || ""
    lang = params["lang"] || "auto"
    category = params["category"] || "news,general"

    if q == "" or engine == "" do
      json(conn, 400, %{error: "Missing q or engine"})
    else
      try do
        Logger.info("[SEARCH] query=\"#{q}\" engine=#{engine}")

        page1 = fetch_search_page(engine, q, category, lang, 1)
        unblocked_count = Enum.count(page1, fn r -> not DomainBlocker.blocked?(r["url"] || "") end)

        page2 =
          if unblocked_count < 5 do
            fetch_search_page(engine, q, category, lang, 2)
          else
            []
          end

        # Deduplicate by URL
        {all_results, _seen} =
          Enum.reduce(page1 ++ page2, {[], MapSet.new()}, fn r, {acc, seen} ->
            u = r["url"] || ""

            if MapSet.member?(seen, u) do
              {acc, seen}
            else
              {acc ++ [r], MapSet.put(seen, u)}
            end
          end)

        results =
          all_results
          |> Enum.filter(fn r -> not DomainBlocker.blocked?(r["url"] || "") end)
          |> Enum.map(fn r ->
            %{title: r["title"] || "", url: r["url"] || "", content: r["content"] || ""}
          end)
          |> Enum.take(10)

        Logger.info("[SEARCH] pool=#{length(all_results)} returned #{length(results)} results: #{inspect(Enum.map(results, & &1.url))}")
        json(conn, 200, %{results: results})
      rescue
        e ->
          Logger.error("[SEARCH] ERROR: #{inspect(e)}")
          json(conn, 500, %{error: inspect(e)})
      end
    end
  end

  # GET /fetch-page?url=...
  def get_fetch_page(conn) do
    params = URI.decode_query(conn.query_string)
    url = params["url"] || ""

    if url == "" do
      json(conn, 400, %{error: "Missing url"})
    else
      text = direct_fetch(url)

      text =
        if String.length(text) < 500 do
          jina_text = jina_fetch(url)

          if String.length(jina_text) >= 500 do
            jina_text
          else
            text
          end
        else
          text
        end

      json(conn, 200, %{text: String.slice(text, 0, 6000)})
    end
  end

  # POST /local-api/* (streaming, no auth)
  def post_local_api(conn, sub) do
    endpoint = get_local_endpoint()
    {:ok, body, conn} = read_body(conn, length: 100_000_000)

    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    url = String.trim_trailing(endpoint, "/") <> "/api/#{sub}"

    result =
      Req.post(url,
        body: body,
        headers: [{"content-type", "application/json"}],
        receive_timeout: :infinity,
        retry: false,
        finch: DmhAi.Finch,
        into: fn {:data, data}, {req, resp} ->
          case chunk(conn, data) do
            {:ok, _conn} -> {:cont, {req, resp}}
            {:error, _} -> {:halt, {req, resp}}
          end
        end
      )

    case result do
      {:error, reason} ->
        Logger.error("[LOCAL-API] ERROR: #{inspect(reason)}")

      _ ->
        :ok
    end

    conn
  end

  # PUT /admin/settings (admin only)
  def put_admin_settings(conn, user) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      d = Jason.decode!(body || "{}")

      # `accounts` removed — accounts now live on the per-pool row
      # (see specs/api_pools.md). Edits flow through /admin/pools/*.
      # `ollamaEndpoint` removed — local Ollama URL is derived from
      # the `miner` pool's base_url (also via /admin/pools/*).
      allowed_keys = ~w(cloudModels compactTurns keepRecent condenseFacts modelLabels openaiKey googleKey anthropicKey confidantModel assistantModel swiftModel oracleModel visionModel kbEmbeddingModel maxToolResultChars logTrace estimatedContextTokens masterCompactTurnThreshold masterCompactFraction minExtractedTextChars ocrPagesPerChunk ocrPageCap)
      allowed = Map.take(d, allowed_keys)

      query!(Repo, "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
        ["admin_cloud_settings", Jason.encode!(allowed)])

      json(conn, 200, %{ok: true})
    end
  end

  # Private helpers

  # Local Ollama URL for browser-direct calls (`/local-api/*`, `/api/*`).
  # Derived from the `miner` pool's base_url with the trailing `/v1`
  # stripped — Ollama's native API surface is /api/*, not /v1/*. Falls
  # back to localhost if the pool isn't configured.
  defp get_local_endpoint do
    case DmhAi.LLM.Pools.fetch("miner") do
      {:ok, %{base_url: base}} ->
        base
        |> String.trim()
        |> String.trim_trailing("/")
        |> String.replace_suffix("/v1", "")

      _ ->
        "http://127.0.0.1:11434"
    end
  rescue
    _ -> "http://127.0.0.1:11434"
  end

  defp proxy_get(base_url, path, headers, opts) do
    url = String.trim_trailing(base_url, "/") <> path
    timeout = Keyword.get(opts, :timeout, 10_000)

    case Req.get(url, headers: headers, receive_timeout: timeout, retry: false, finch: DmhAi.Finch) do
      {:ok, resp} ->
        # Req 0.5+ returns header values as lists; normalize to strings
        resp_headers = Enum.map(resp.headers, fn {k, v} ->
          {k, if(is_list(v), do: List.first(v) || "", else: v)}
        end)
        body = ensure_string(resp.body)
        {:ok, resp.status, resp_headers, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_search_page(engine, q, category, lang, pageno) do
    params = %{q: q, format: "json", categories: category, language: lang, pageno: pageno}
    url = String.trim_trailing(engine, "/") <> "/search?" <> URI.encode_query(params)

    try do
      case Req.get(url,
             headers: [{"User-Agent", "Mozilla/5.0"}],
             receive_timeout: 20_000,
             retry: false,
             finch: DmhAi.Finch
           ) do
        {:ok, %{status: 200, body: body}} ->
          data =
            case body do
              b when is_binary(b) -> Jason.decode!(b)
              b when is_map(b) -> b
              _ -> %{}
            end

          data["results"] || []

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  defp direct_fetch(url) do
    try do
      case Req.get(url,
             headers: [
               {"User-Agent", @user_agent},
               {"Accept", "text/html,text/plain"}
             ],
             receive_timeout: 6_000,
             max_redirects: 5,
             retry: false,
             finch: DmhAi.Finch
           ) do
        {:ok, %{status: 200, headers: headers, body: body}} ->
          ct = Enum.find_value(headers, "", fn {k, v} ->
            if String.downcase(k) == "content-type", do: v
          end)

          if String.contains?(ct, "html") or String.contains?(ct, "text/plain") do
            raw = ensure_bytes(body) |> take_bytes(120_000)
            text = Html.html_to_text(raw)
            Logger.info("[FETCH-PAGE] direct ok url=#{String.slice(url, 0, 80)} chars=#{String.length(text)}")
            text
          else
            Logger.info("[FETCH-PAGE] skip non-html: #{String.slice(url, 0, 80)} ct=#{ct}")
            ""
          end

        _ ->
          ""
      end
    rescue
      e ->
        err_str = inspect(e)
        Logger.info("[FETCH-PAGE] direct err url=#{String.slice(url, 0, 80)} err=#{err_str}")

        if timeout_error?(e) do
          DomainBlocker.record_timeout(url)
        end

        ""
    end
  end

  defp jina_fetch(url) do
    try do
      jina_url = "https://r.jina.ai/" <> url

      case Req.get(jina_url,
             headers: [
               {"User-Agent", "Mozilla/5.0"},
               {"Accept", "text/plain"},
               {"X-No-Cache", "true"}
             ],
             receive_timeout: 7_000,
             retry: false,
             finch: DmhAi.Finch
           ) do
        {:ok, %{status: 200, body: body}} ->
          jina_text = ensure_string(body) |> take_bytes(200_000)

          if String.length(jina_text) >= 500 do
            result =
              jina_text
              |> then(&Regex.replace(~r/(\d)([A-Za-z])/, &1, "\\1 \\2"))
              |> then(&Regex.replace(~r/([A-Za-z])(\d)/, &1, "\\1 \\2"))
              |> then(&Regex.replace(~r/([a-z])([A-Z])/, &1, "\\1 \\2"))

            Logger.info("[FETCH-PAGE] jina ok url=#{String.slice(url, 0, 80)} chars=#{String.length(result)}")
            result
          else
            Logger.info("[FETCH-PAGE] jina empty url=#{String.slice(url, 0, 80)} chars=#{String.length(jina_text)}")
            ""
          end

        _ ->
          ""
      end
    rescue
      e ->
        err_str = inspect(e)
        Logger.info("[FETCH-PAGE] jina err url=#{String.slice(url, 0, 80)} err=#{err_str}")

        if timeout_error?(e) do
          DomainBlocker.record_timeout(url)
        end

        ""
    end
  end

  defp ensure_string(body) when is_binary(body), do: body
  defp ensure_string(body) when is_map(body), do: Jason.encode!(body)
  defp ensure_string(body) when is_list(body), do: to_string(body)
  defp ensure_string(_), do: ""

  defp ensure_bytes(body) when is_binary(body), do: body
  defp ensure_bytes(body), do: ensure_string(body)

  defp timeout_error?(%Req.TransportError{reason: :timeout}), do: true
  defp timeout_error?(%Req.TransportError{reason: :closed}), do: false
  defp timeout_error?(%{reason: :timeout}), do: true
  defp timeout_error?(e) do
    msg = inspect(e) |> String.downcase()
    String.contains?(msg, "timeout") or String.contains?(msg, "timed out")
  end

  defp take_bytes(bin, len) when byte_size(bin) <= len, do: bin
  defp take_bytes(bin, len), do: binary_part(bin, 0, len)
end
