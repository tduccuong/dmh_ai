# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Handlers.Proxy do
  import Plug.Conn
  alias Dmhai.Repo
  alias Dmhai.DomainBlocker
  alias Dmhai.Util.Html
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

    json(conn, 200, Map.put(data, "systemModels", Dmhai.Agent.AgentSettings.system_model_names()))
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

  # GET /registry?q=...
  def get_registry(conn) do
    params = URI.decode_query(conn.query_string)
    q = String.trim(params["q"] || "")

    if q == "" do
      json(conn, 200, %{models: []})
    else
      try do
        search_url = "https://ollama.com/search?" <> URI.encode_query(%{q: q})

        case Req.get(search_url,
               headers: [{"User-Agent", @user_agent}, {"Accept", "text/html"}],
               receive_timeout: 10_000,
               retry: false,
               finch: Dmhai.Finch
             ) do
          {:ok, %{status: 200, body: body}} ->
            body_str = ensure_string(body)
            model_names = extract_model_names(body_str)

            cloud_results =
              model_names
              |> Enum.take(8)
              |> Task.async_stream(
                fn model_name ->
                  get_cloud_tags(model_name)
                end,
                max_concurrency: 6,
                timeout: 10_000
              )
              |> Enum.flat_map(fn
                {:ok, tags} -> tags
                _ -> []
              end)

            models = Enum.map(cloud_results, fn name -> %{name: name} end) |> Enum.take(20)
            json(conn, 200, %{models: models})

          {:ok, resp} ->
            Logger.error("[REGISTRY] unexpected status: #{resp.status}")
            json(conn, 500, %{error: "Registry fetch failed"})

          {:error, reason} ->
            Logger.error("[REGISTRY] ERROR: #{inspect(reason)}")
            json(conn, 500, %{error: inspect(reason)})
        end
      rescue
        e ->
          Logger.error("[REGISTRY] ERROR: #{inspect(e)}")
          json(conn, 500, %{error: inspect(e)})
      end
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
        finch: Dmhai.Finch,
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

  # POST /cloud-api/* (streaming, auth required)
  def post_cloud_api(conn, _user, sub) do
    cloud_key = get_req_header(conn, "x-cloud-key") |> List.first() |> then(&(if &1, do: String.trim(&1), else: ""))

    if cloud_key == "" do
      json(conn, 400, %{error: "Missing cloud API key"})
    else
      {:ok, body, conn} = read_body(conn, length: 100_000_000)

      # First check for upstream errors before starting stream
      # We need to peek at the response status; use streaming and detect error status
      conn =
        conn
        |> put_resp_content_type("application/x-ndjson")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      url = "https://ollama.com/api/#{sub}"

      bytes_key = {__MODULE__, :bytes, self()}
      Process.put(bytes_key, 0)

      result =
        Req.post(url,
          body: body,
          headers: [
            {"authorization", "Bearer #{cloud_key}"},
            {"content-type", "application/json"}
          ],
          receive_timeout: :infinity,
          retry: false,
          finch: Dmhai.Finch,
          into: fn {:data, data}, {req, resp} ->
            Process.put(bytes_key, Process.get(bytes_key) + byte_size(data))
            case chunk(conn, data) do
              {:ok, _conn} -> {:cont, {req, resp}}
              {:error, _} -> {:halt, {req, resp}}
            end
          end
        )

      bytes_sent = Process.get(bytes_key)

      case result do
        {:error, reason} ->
          Logger.error("[CLOUD-API] ERROR: #{inspect(reason)}")

        {:ok, %{status: status}} when status >= 400 ->
          Logger.error("[CLOUD-API] upstream error status=#{status} sub=#{sub} bytes_sent=#{bytes_sent}")

        {:ok, %{status: status}} when bytes_sent == 0 ->
          Logger.error("[CLOUD-API] upstream returned 0 bytes status=#{status} sub=#{sub} req_size=#{byte_size(body)}")

        _ ->
          :ok
      end

      conn
    end
  end

  # PUT /admin/settings (admin only)
  def put_admin_settings(conn, user) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      d = Jason.decode!(body || "{}")

      allowed_keys = ~w(accounts cloudModels ollamaEndpoint compactTurns keepRecent condenseFacts modelLabels openaiKey googleKey anthropicKey confidantModel assistantModel workerModel webSearchModel imageDescriberModel videoDescriberModel profileExtractorModel maxToolResultChars workerContextN workerContextM logTrace)
      allowed = Map.take(d, allowed_keys)

      query!(Repo, "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
        ["admin_cloud_settings", Jason.encode!(allowed)])

      json(conn, 200, %{ok: true})
    end
  end

  # Private helpers

  defp get_local_endpoint do
    result = query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"])

    case result.rows do
      [[v] | _] ->
        data = Jason.decode!(v || "{}")
        ep = String.trim(data["ollamaEndpoint"] || "") |> String.trim_trailing("/")
        if ep == "", do: "http://127.0.0.1:11434", else: ep

      _ ->
        "http://127.0.0.1:11434"
    end
  end

  defp proxy_get(base_url, path, headers, opts) do
    url = String.trim_trailing(base_url, "/") <> path
    timeout = Keyword.get(opts, :timeout, 10_000)

    case Req.get(url, headers: headers, receive_timeout: timeout, retry: false, finch: Dmhai.Finch) do
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
             finch: Dmhai.Finch
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
             finch: Dmhai.Finch
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
             finch: Dmhai.Finch
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

  defp extract_model_names(body) do
    regex = ~r/href=["'](?:https:\/\/ollama\.com)?\/library\/([\w][\w.\-]{0,60})["']/

    Regex.scan(regex, body, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
  end

  defp get_cloud_tags(model_name) do
    try do
      murl = "https://ollama.com/library/#{model_name}"

      case Req.get(murl,
             headers: [{"User-Agent", @user_agent}, {"Accept", "text/html"}],
             receive_timeout: 10_000,
             retry: false,
             finch: Dmhai.Finch
           ) do
        {:ok, %{status: 200, body: body}} ->
          mb = ensure_string(body)

          # href="/library/model:tag" patterns that contain "cloud"
          escaped = Regex.escape(model_name)
          pattern = Regex.compile!("/library/" <> escaped <> ":(\\w[^\"'>\\s]{0,60})")

          tags =
            Regex.scan(pattern, mb, capture: :all_but_first)
            |> Enum.map(fn [t] -> t end)
            |> Enum.filter(&String.contains?(&1, "cloud"))
            |> MapSet.new()

          # Fallback: any quoted token matching *cloud*
          tags =
            if MapSet.size(tags) == 0 do
              Regex.scan(~r/["']([a-z0-9][a-z0-9._\-]*cloud[a-z0-9._\-]*)["']/, mb, capture: :all_but_first)
              |> Enum.map(fn [t] -> t end)
              |> Enum.filter(fn t -> Regex.match?(~r/^[\w.\-]+$/, t) and String.length(t) <= 60 end)
              |> MapSet.new()
            else
              tags
            end

          tags |> Enum.sort() |> Enum.map(fn t -> model_name <> ":" <> t end)

        _ ->
          []
      end
    rescue
      _ -> []
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
