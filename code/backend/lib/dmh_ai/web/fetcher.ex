# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Web.Fetcher do
  @moduledoc """
  Orchestrator for robust web fetching in the face of CMP walls.

  Flow:
    1. Primary fetch (consent cookies seeded + modern UA).
    2. If response OK and no CMP fingerprint → extract content via Reader,
       fall back to flat html_to_text if Reader rejects.
    3. If CMP detected → walk AMP variants, then archive mirrors.
    4. If nothing works → `{:error, {:cmp_wall, url, tried: [...]}}`.

  Returns `{:ok, %{url, final_url, content, title, source, cmp: vendor|nil, tried: [...]}}`
  or `{:error, reason}`.

  Test seam: pass `http_fn: fn url, headers -> {:ok, %{status: s, body: b}} | {:error, r} end`
  in opts. Defaults to Req.
  """

  require Logger

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Util.{Html, Url}
  alias DmhAi.Web.{CmpDetector, ConsentSeeder, Fallback, ReaderExtractor}

  @user_agent "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0"
  @default_timeout_ms 15_000
  @jina_timeout_ms    10_000
  @max_chars 20_000

  # ── Three-gate binary filter (see specs/architecture.md or pipelines/url.ex) ──
  #
  # Gate 1 (caller's job, e.g. url.ex):
  #   pre-fetch URL extension blocklist — saves a round-trip on
  #   obvious binaries (.zip/.png/.exe). Cheap, pattern-only.
  #
  # Gate 2 (this module, response-time):
  #   Content-Type header check. If the server says binary, we don't
  #   even try to extract.
  #
  # Gate 3 (this module, response-time fallback):
  #   First-bytes sniff. Some servers omit Content-Type or send
  #   `application/octet-stream` for everything. NUL bytes in the
  #   first 512 bytes are an essentially-zero false-positive signal
  #   that the payload is binary. Fires only when Gate 2 was
  #   inconclusive.
  @text_content_type_prefixes ~w(text/)

  @text_content_type_exact ~w(
    application/xhtml+xml
    application/xml
    application/atom+xml
    application/rss+xml
    application/json
    application/ld+json
    application/javascript
    application/x-yaml
    application/yaml
  )

  @sniff_bytes 512

  @doc """
  Fetch `url` with CMP-aware fallback behaviour.

  Options:
    * `:http_fn` — 2-arity `fn url, headers -> {:ok, %{status, body}} | {:error, term} end`.
    * `:timeout_ms` — per-request timeout (default 15_000).
    * `:max_chars` — hard truncate on returned content (default 20_000).
    * `:user_agent` — overrides the default UA.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    case Application.get_env(:dmh_ai, :__fetcher_stub__) do
      stub when is_function(stub, 1) ->
        # Test hook: callers in tests (mostly Primitive 0.2 ingest
        # flows) replace upstream HTTP with a deterministic response.
        # See specs/web_fetcher.md.
        stub.(url)

      _ ->
        case Url.parse(url) do
          nil -> {:error, {:invalid_url, url}}
          _   -> do_fetch(url, opts)
        end
    end
  end

  defp do_fetch(url, opts) do
    state = %{
      original_url: url,
      tried: [],
      cmp: nil,
      max_chars: Keyword.get(opts, :max_chars, @max_chars),
      opts: opts
    }

    case attempt(url, state) do
      {:ok, result} -> {:ok, result}

      {:cmp, vendor, state} ->
        Logger.info("[Web.Fetcher] CMP=#{vendor} detected for #{url} — trying fallbacks")
        state = %{state | cmp: vendor}
        case walk_fallbacks(Fallback.all_variants(url), state) do
          {:ok, _} = ok -> ok
          {:error, _}   -> try_jina(url, state)
        end

      {:error, reason, state} ->
        {:error, {:fetch_failed, reason, url, Enum.reverse(state.tried)}}
    end
  end

  # Walk a list of fallback URLs. First CLEAN success wins.
  defp walk_fallbacks([], state) do
    {:error, {:cmp_wall,
              state.original_url,
              cmp: state.cmp,
              tried: Enum.reverse(state.tried)}}
  end

  defp walk_fallbacks([url | rest], state) do
    case attempt(url, state) do
      {:ok, result}            -> {:ok, result}
      {:cmp, _vendor, state}   -> walk_fallbacks(rest, state)
      {:error, _reason, state} -> walk_fallbacks(rest, state)
    end
  end

  # Issue one HTTP request, classify the response, return:
  #   {:ok, result_map}
  #   {:cmp, vendor, updated_state}   — CMP wall, try a fallback
  #   {:error, reason, updated_state} — hard failure, try a fallback if any left
  defp attempt(url, state) do
    headers = ConsentSeeder.request_headers(user_agent(state.opts))
    http_fn = http_fn(state.opts)
    state   = %{state | tried: [url | state.tried]}

    case http_fn.(url, headers) do
      {:ok, %{status: status, body: body} = resp} when status in 200..299 ->
        final_url = Map.get(resp, :final_url, url)
        resp_headers = Map.get(resp, :headers, [])

        # Gate 2: Content-Type. If the server says binary, drop now.
        # Gate 3: NUL-byte sniff for the first @sniff_bytes when
        # Content-Type is missing/ambiguous (HEAD-less servers,
        # `application/octet-stream` everywhere, etc.).
        case classify_payload(resp_headers, body) do
          {:reject, reason} ->
            {:error, reason, state}

          :ok ->
            case CmpDetector.detect(body) do
              {:cmp, vendor} ->
                {:cmp, vendor, %{state | cmp: vendor}}

              :clean ->
                extractor    = Keyword.get(state.opts, :extractor, :general)
                {title, text} = extract(body, final_url, extractor)
                if byte_size(text) == 0 do
                  {:error, :empty_content, state}
                else
                  {:ok, build_result(url, final_url, title, text, body, state)}
                end
            end
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Combines Gate 2 (content-type) and Gate 3 (body sniff) into a
  # single decision. Order matters: header-stated binary always wins
  # over body-sniff (even if a binary file's first 512 bytes happen
  # to contain no NUL).
  defp classify_payload(headers, body) do
    case content_type(headers) do
      {:ok, ct} ->
        if text_content_type?(ct) do
          :ok
        else
          {:reject, {:non_text_content_type, ct}}
        end

      :missing ->
        # No Content-Type header. Fall through to body sniff.
        if body_looks_text?(body) do
          :ok
        else
          {:reject, :binary_body_sniffed}
        end
    end
  end

  defp content_type(headers) when is_list(headers) do
    Enum.find_value(headers, :missing, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == "content-type", do: {:ok, parse_content_type(v)}, else: nil

      _ ->
        nil
    end)
  end

  defp content_type(headers) when is_map(headers) do
    case Map.get(headers, "content-type") || Map.get(headers, "Content-Type") do
      nil   -> :missing
      [v | _] when is_binary(v) -> {:ok, parse_content_type(v)}
      v when is_binary(v)        -> {:ok, parse_content_type(v)}
      _ -> :missing
    end
  end

  defp content_type(_), do: :missing

  # Strip charset and other params: "text/html; charset=utf-8" → "text/html"
  defp parse_content_type(v) do
    v |> to_string() |> String.split(";") |> hd() |> String.trim() |> String.downcase()
  end

  defp text_content_type?(ct) when is_binary(ct) do
    Enum.any?(@text_content_type_prefixes, &String.starts_with?(ct, &1)) or
      ct in @text_content_type_exact
  end

  defp text_content_type?(_), do: false

  # Body sniff: a NUL byte (0x00) in the first @sniff_bytes is an
  # essentially-zero-FP signal that the payload is binary — text
  # encodings used on the web (UTF-8, ASCII, ISO-8859-*) don't
  # produce embedded NULs. UTF-16 does, but UTF-16-served HTML is
  # vanishingly rare and our extractors couldn't parse it either.
  defp body_looks_text?(body) when is_binary(body) do
    prefix_len = min(byte_size(body), @sniff_bytes)
    prefix     = binary_part(body, 0, prefix_len)
    not String.contains?(prefix, <<0>>)
  end

  defp body_looks_text?(_), do: true

  defp extract(body, source_url, extractor) do
    extracted =
      case extractor do
        :kb -> ReaderExtractor.extract_for_kb(body, source_url)
        _   -> ReaderExtractor.extract(body, source_url)
      end

    case extracted do
      %{title: title, text: text} when is_binary(text) and byte_size(text) > 0 ->
        {title, text}

      _ ->
        # Reader gave up — fall back to flat text dump.
        {nil, Html.html_to_text(body)}
    end
  end

  defp build_result(origin_url, final_url, title, text, raw_body, state) do
    truncated? = String.length(text) > state.max_chars
    text       = if truncated?, do: String.slice(text, 0, state.max_chars), else: text

    source =
      cond do
        state.cmp == nil                                -> :direct
        origin_url == state.original_url                -> :direct
        String.contains?(final_url, "archive.ph")       -> :archive_today
        String.contains?(final_url, "web.archive.org")  -> :wayback
        true                                            -> :amp_or_mirror
      end

    base = %{
      url:        state.original_url,
      final_url:  final_url,
      title:      title,
      content:    text,
      truncated:  truncated?,
      source:     source,
      cmp:        state.cmp,
      tried:      Enum.reverse(state.tried)
    }

    # `:include_html` exposes the raw body so callers (the URL crawl
    # pipeline) can re-parse for outbound links without a second
    # fetch. Off by default — keeps the result map small for the
    # common single-page chat use.
    if Keyword.get(state.opts, :include_html, false) do
      Map.put(base, :html, raw_body)
    else
      base
    end
  end

  # ── Jina reader — last-resort fallback after all URL variants fail ──────────

  defp try_jina(url, state) do
    jina_url = AgentSettings.jina_base_url() <> url
    Logger.info("[Web.Fetcher] trying Jina reader for #{url}")

    headers = [
      {"User-Agent", user_agent(state.opts)},
      {"Accept", "text/plain"},
      {"X-No-Cache", "true"}
    ]

    result =
      try do
        Req.get(jina_url,
          headers:         headers,
          receive_timeout: @jina_timeout_ms,
          decode_body:     false
        )
      rescue
        _ -> {:error, :jina_error}
      end

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        text = if is_binary(body), do: body, else: to_string(body)

        if String.length(text) < 200 do
          cmp_wall_error(url, state)
        else
          truncated? = String.length(text) > state.max_chars
          content    = if truncated?, do: String.slice(text, 0, state.max_chars), else: text

          {:ok, %{
            url:       state.original_url,
            final_url: jina_url,
            title:     nil,
            content:   content,
            truncated: truncated?,
            source:    :jina_reader,
            cmp:       state.cmp,
            tried:     Enum.reverse([jina_url | state.tried])
          }}
        end

      _ ->
        cmp_wall_error(url, state)
    end
  end

  defp cmp_wall_error(url, state) do
    {:error, {:cmp_wall, url, cmp: state.cmp, tried: Enum.reverse(state.tried)}}
  end

  # ── options / injection ──────────────────────────────────────────────

  defp user_agent(opts), do: Keyword.get(opts, :user_agent, @user_agent)

  defp http_fn(opts) do
    case Keyword.get(opts, :http_fn) do
      fun when is_function(fun, 2) -> fun
      _ -> &default_http_fn(&1, &2)
    end
  end

  defp default_http_fn(url, headers) do
    case Req.get(url,
           headers: headers,
           redirect: true,
           receive_timeout: @default_timeout_ms,
           decode_body: false
         ) do
      {:ok, resp} ->
        # Req doesn't expose the post-redirect URL on %Req.Response{} directly;
        # fall back to the input URL. Tests supply final_url via the mock.
        # `resp.headers` is a `%{lowercased_name => [value, …]}` map — pass it
        # through so the caller can inspect Content-Type without a HEAD round-trip.
        {:ok, %{status: resp.status, body: resp.body, final_url: url, headers: resp.headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
