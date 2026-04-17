# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Web.Fetcher do
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

  alias Dmhai.Util.{Html, Url}
  alias Dmhai.Web.{CmpDetector, ConsentSeeder, Fallback, ReaderExtractor}

  @user_agent "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0"
  @default_timeout_ms 15_000
  @max_chars 20_000

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
    case Url.parse(url) do
      nil -> {:error, {:invalid_url, url}}
      _   -> do_fetch(url, opts)
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
        walk_fallbacks(Fallback.all_variants(url), %{state | cmp: vendor})

      {:error, reason, state} ->
        if Map.get(state, :cmp) do
          walk_fallbacks(Fallback.all_variants(url), state)
        else
          {:error, {:fetch_failed, reason, url, Enum.reverse(state.tried)}}
        end
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

        case CmpDetector.detect(body) do
          {:cmp, vendor} ->
            {:cmp, vendor, %{state | cmp: vendor}}

          :clean ->
            {title, text} = extract(body, final_url)
            if byte_size(text) == 0 do
              {:error, :empty_content, state}
            else
              {:ok, build_result(url, final_url, title, text, state)}
            end
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp extract(body, source_url) do
    case ReaderExtractor.extract(body, source_url) do
      %{title: title, text: text} when is_binary(text) and byte_size(text) > 0 ->
        {title, text}

      _ ->
        # Reader gave up — fall back to flat text dump.
        {nil, Html.html_to_text(body)}
    end
  end

  defp build_result(origin_url, final_url, title, text, state) do
    truncated? = String.length(text) > state.max_chars
    text       = if truncated?, do: String.slice(text, 0, state.max_chars), else: text

    source =
      cond do
        state.cmp == nil             -> :direct
        origin_url == state.original_url -> :direct
        String.contains?(final_url, "archive.ph")       -> :archive_today
        String.contains?(final_url, "web.archive.org")  -> :wayback
        true                                            -> :amp_or_mirror
      end

    %{
      url:        state.original_url,
      final_url:  final_url,
      title:      title,
      content:    text,
      truncated:  truncated?,
      source:     source,
      cmp:        state.cmp,
      tried:      Enum.reverse(state.tried)
    }
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
        {:ok, %{status: resp.status, body: resp.body, final_url: url}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
