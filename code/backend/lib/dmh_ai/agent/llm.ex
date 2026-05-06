# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.LLM do
  @moduledoc """
  Unified LLM client using direct Req.post to provider APIs.

  ## Model string format

      "<pool>::<model>"

  Where `<pool>` matches a row in the `pools` table (see
  `DmhAi.LLM.Pools`) and `<model>` is whatever the upstream provider
  expects. Resolution looks up the pool, runs account rotation, and
  returns a struct with the resolved base_url + api_key. Adding a new
  endpoint is a row insert, not a code change. See `specs/api_pools.md`.

  ### Examples

      "ollama-cloud::gemma4:31b-cloud"
      "miner::llama3.2:3b"
      "miner::qwen3-embedding:0.6b"

  ## Entry points

  - `stream/4` — streaming; sends `{:chunk, token}` to reply_pid.
                 Returns `{:ok, full_text}` or `{:ok, {:tool_calls, calls}}`.
  - `call/3`   — non-streaming; returns `{:ok, text}` or `{:ok, {:tool_calls, calls}}`.
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Agent.LogTrace
  alias DmhAi.LLM.{Pools, AccountRotation}
  require Logger

  # ─── Wire-protocol adapter dispatch ────────────────────────────────────────
  #
  # The adapter encapsulates everything that differs between wire
  # protocols: endpoint URL, request body shape, response parsing,
  # streaming line parser, and post-stream consolidation. The rest
  # (account rotation, retry-on-throttle, transport timing,
  # thinking-tag extraction, message sanitisation) stays here.
  #
  # Dispatch is protocol-driven and fail-loud — every pool declares
  # its wire protocol at create time and the resolver carries that
  # value through unchanged. An unknown value here is a bug in
  # `Pools.create/1` validation, not a runtime fallback target.
  defp adapter_for(%{protocol: "openai"}),    do: DmhAi.LLM.Adapters.OpenAI
  defp adapter_for(%{protocol: "ollama"}),    do: DmhAi.LLM.Adapters.Ollama
  defp adapter_for(%{protocol: "anthropic"}), do: DmhAi.LLM.Adapters.Anthropic

  defp adapter_for(%{protocol: other}) do
    raise ArgumentError,
          "unknown pool protocol #{inspect(other)} — Pools validation should " <>
            "have rejected this. Allowed: #{inspect(DmhAi.LLM.Pools.valid_protocols())}"
  end

  # Transient-error retry budget for a single account before rotation
  # kicks in. Three retries with @server_error_delay_ms backoff = ~6s
  # total before we mark the account throttled and pick the next one.
  # Bounded by `AgentSettings.llm_total_attempts/0` (the global cap
  # across within-account retries + cross-account rotation cycles —
  # see arch_wiki §Retry cap).
  @server_error_retries 3
  @server_error_delay_ms 2_000

  # ─── Public API ────────────────────────────────────────────────────────────

  @spec stream(String.t(), list(map()), pid(), keyword()) ::
          {:ok, String.t() | {:tool_calls, list()}} | {:error, term()}
  def stream(model_str, messages, reply_pid, opts \\ []) do
    # Test hook: Application.put_env(:dmh_ai, :__llm_stream_stub__, fn model, msgs, pid, opts -> ... end)
    # Stub must return {:ok, text}, {:ok, {:tool_calls, calls}}, or {:error, reason}.
    # The stub is responsible for sending {:chunk, token} / {:thinking, token} to reply_pid if desired.
    if stub = Application.get_env(:dmh_ai, :__llm_stream_stub__) do
      stub.(model_str, messages, reply_pid, opts)
    else
      tools       = Keyword.get(opts, :tools, [])
      llm_options = Keyword.get(opts, :options, %{})
      on_tokens   = Keyword.get(opts, :on_tokens, nil)
      trace       = Keyword.get(opts, :trace)
      Logger.info("[LLM] stream #{model_str} msgs=#{length(messages)} tools=#{length(tools)}")
      DmhAi.SysLog.log("[LLM] stream model=#{model_str} msgs=#{length(messages)} tools=#{length(tools)}\n  #{log_messages(messages)}")

      result =
        case Pools.resolve(model_str) do
          {:ok, resolved} ->
            adapter = adapter_for(resolved)
            sanitized =
              sanitize_messages(resolved.protocol, messages, resolved.model)
              |> adapter.normalize_messages()
            options = inject_pool_options(resolved, llm_options)
            body = adapter.build_body(resolved.model, sanitized, tools, true, options)
            do_pool_stream(resolved, adapter, body, reply_pid, model_str, on_tokens,
                           AgentSettings.llm_total_attempts())

          {:error, :all_throttled, retry_ms} ->
            Logger.error("[LLM] all accounts throttled in pool, retry in #{retry_ms}ms #{model_str}")
            {:error, :rate_limited}

          {:error, :unknown_pool} ->
            {:error, "unknown pool in model string: #{inspect(model_str)}"}

          {:error, :invalid_format} ->
            {:error, "invalid model format: #{inspect(model_str)} (expected <pool>::<model>)"}
        end

      maybe_trace(trace, model_str, messages, tools, result)
      result
    end
  end

  @spec call(String.t(), list(map()), keyword()) ::
          {:ok, String.t() | {:tool_calls, list()}} | {:error, term()}
  def call(model_str, messages, opts \\ []) do
    # Test hook: Application.put_env(:dmh_ai, :__llm_call_stub__, fn model, msgs, opts -> ... end)
    # Stub must return {:ok, text}, {:ok, {:tool_calls, calls}}, or {:error, reason}.
    if stub = Application.get_env(:dmh_ai, :__llm_call_stub__) do
      stub.(model_str, messages, opts)
    else
      tools       = Keyword.get(opts, :tools, [])
      llm_options = Keyword.get(opts, :options, %{})
      on_tokens   = Keyword.get(opts, :on_tokens, nil)
      trace       = Keyword.get(opts, :trace)
      Logger.info("[LLM] call #{model_str} msgs=#{length(messages)} tools=#{length(tools)}")
      DmhAi.SysLog.log("[LLM] call model=#{model_str} msgs=#{length(messages)} tools=#{length(tools)}\n  #{log_messages(messages)}")

      result =
        case Pools.resolve(model_str) do
          {:ok, resolved} ->
            adapter = adapter_for(resolved)
            sanitized =
              sanitize_messages(resolved.protocol, messages, resolved.model)
              |> adapter.normalize_messages()
            options = inject_pool_options(resolved, llm_options)
            body = adapter.build_body(resolved.model, sanitized, tools, false, options)
            do_pool_call(resolved, adapter, body, model_str, on_tokens,
                         AgentSettings.llm_total_attempts())

          {:error, :all_throttled, retry_ms} ->
            Logger.error("[LLM] all accounts throttled in pool, retry in #{retry_ms}ms #{model_str}")
            {:error, :rate_limited}

          {:error, :unknown_pool} ->
            {:error, "unknown pool in model string: #{inspect(model_str)}"}

          {:error, :invalid_format} ->
            {:error, "invalid model format: #{inspect(model_str)} (expected <pool>::<model>)"}
        end

      maybe_trace(trace, model_str, messages, tools, result)
      result
    end
  end

  # ─── Pool-driven request helpers ────────────────────────────────────────────

  # Protocol-specific auth headers. OpenAI/Ollama take a Bearer token;
  # Anthropic rejects Bearer and requires `x-api-key` + the
  # `anthropic-version` header. Pools without an api_key (LAN dev
  # endpoints, no-auth shims) get an empty list.
  defp auth_headers(%{protocol: "anthropic", api_key: key}),
    do: DmhAi.LLM.Adapters.Anthropic.auth_headers(key)

  defp auth_headers(%{api_key: key}) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer " <> key}]

  defp auth_headers(_), do: []

  # Streaming wrapper with per-account fallback. On rate-limit / quota
  # exhaust against the chosen account, marks it throttled (persisted via
  # AccountRotation) and resolves a fresh account from the same pool.
  # `attempts_left` is the global cap (default
  # `AgentSettings.llm_total_attempts/0`) shared with cross-account
  # rotation in `retry_after_rotation`. Each Req.post attempt
  # decrements it; reaching 0 returns `{:error, :attempts_exhausted}`.
  defp do_pool_stream(resolved, adapter, body, reply_pid, model_str, on_tokens, attempts_left, retries \\ @server_error_retries)

  defp do_pool_stream(_resolved, _adapter, _body, _reply_pid, model_str, _on_tokens, attempts_left, _retries)
       when attempts_left <= 0 do
    Logger.error("[LLM] global attempt cap reached, giving up #{model_str}")
    {:error, :attempts_exhausted}
  end

  defp do_pool_stream(resolved, adapter, body, reply_pid, model_str, on_tokens, attempts_left, retries) do
    url     = adapter.chat_endpoint_url(resolved)
    headers = auth_headers(resolved)
    attempts_left = attempts_left - 1

    case do_stream_request(url, headers, body, reply_pid, model_str, on_tokens, adapter) do
      {:error, :quota_exhausted} ->
        hours = AgentSettings.quota_exhausted_throttle_hours()
        until = System.os_time(:millisecond) + :timer.hours(hours)
        Logger.warning("[LLM] account #{resolved.account_name} weekly quota exhausted, throttling #{hours}h")
        AccountRotation.mark_throttled(resolved.pool_name, resolved.account_name, until)
        retry_after_rotation(model_str, body, reply_pid, on_tokens, :stream, attempts_left)

      {:error, {:rate_limited, ms}} ->
        until = System.os_time(:millisecond) + ms
        Logger.warning("[LLM] account #{resolved.account_name} rate-limited (Retry-After=#{div(ms, 1000)}s)")
        AccountRotation.mark_throttled(resolved.pool_name, resolved.account_name, until)
        retry_after_rotation(model_str, body, reply_pid, on_tokens, :stream, attempts_left)

      {:error, :rate_limited} ->
        secs = AgentSettings.rate_limit_throttle_secs()
        until = System.os_time(:millisecond) + :timer.seconds(secs)
        Logger.warning("[LLM] account #{resolved.account_name} rate-limited (no Retry-After), throttling #{secs}s")
        AccountRotation.mark_throttled(resolved.pool_name, resolved.account_name, until)
        retry_after_rotation(model_str, body, reply_pid, on_tokens, :stream, attempts_left)

      {:error, :server_error} when retries > 0 and attempts_left > 0 ->
        Logger.warning("[LLM] transient server error, retrying in #{@server_error_delay_ms}ms (#{retries} left, #{attempts_left} budget) #{model_str}")
        Process.sleep(@server_error_delay_ms)
        do_pool_stream(resolved, adapter, body, reply_pid, model_str, on_tokens, attempts_left, retries - 1)

      {:error, :server_error} ->
        Logger.error("[LLM] server error persists after retries, account=#{resolved.account_name} #{model_str}")
        retry_after_rotation(model_str, body, reply_pid, on_tokens, :stream, attempts_left)

      other ->
        other
    end
  end

  # Non-streaming counterpart.
  defp do_pool_call(resolved, adapter, body, model_str, on_tokens, attempts_left, retries \\ @server_error_retries)

  defp do_pool_call(_resolved, _adapter, _body, model_str, _on_tokens, attempts_left, _retries)
       when attempts_left <= 0 do
    Logger.error("[LLM] global attempt cap reached, giving up #{model_str}")
    {:error, :attempts_exhausted}
  end

  defp do_pool_call(resolved, adapter, body, model_str, on_tokens, attempts_left, retries) do
    url     = adapter.chat_endpoint_url(resolved)
    headers = auth_headers(resolved)
    attempts_left = attempts_left - 1

    case do_call_request(url, headers, body, model_str, on_tokens, adapter) do
      {:error, :quota_exhausted} ->
        hours = AgentSettings.quota_exhausted_throttle_hours()
        until = System.os_time(:millisecond) + :timer.hours(hours)
        Logger.warning("[LLM] account #{resolved.account_name} weekly quota exhausted, throttling #{hours}h")
        AccountRotation.mark_throttled(resolved.pool_name, resolved.account_name, until)
        retry_after_rotation(model_str, body, nil, on_tokens, :call, attempts_left)

      {:error, {:rate_limited, ms}} ->
        until = System.os_time(:millisecond) + ms
        Logger.warning("[LLM] account #{resolved.account_name} rate-limited (Retry-After=#{div(ms, 1000)}s)")
        AccountRotation.mark_throttled(resolved.pool_name, resolved.account_name, until)
        retry_after_rotation(model_str, body, nil, on_tokens, :call, attempts_left)

      {:error, :rate_limited} ->
        secs = AgentSettings.rate_limit_throttle_secs()
        until = System.os_time(:millisecond) + :timer.seconds(secs)
        Logger.warning("[LLM] account #{resolved.account_name} rate-limited (no Retry-After), throttling #{secs}s")
        AccountRotation.mark_throttled(resolved.pool_name, resolved.account_name, until)
        retry_after_rotation(model_str, body, nil, on_tokens, :call, attempts_left)

      {:error, :server_error} when retries > 0 and attempts_left > 0 ->
        Logger.warning("[LLM] transient server error, retrying in #{@server_error_delay_ms}ms (#{retries} left, #{attempts_left} budget) #{model_str}")
        Process.sleep(@server_error_delay_ms)
        do_pool_call(resolved, adapter, body, model_str, on_tokens, attempts_left, retries - 1)

      {:error, :server_error} ->
        Logger.error("[LLM] server error persists after retries, account=#{resolved.account_name} #{model_str}")
        retry_after_rotation(model_str, body, nil, on_tokens, :call, attempts_left)

      other ->
        other
    end
  end

  # After the chosen account got throttled or persistently 5xx'd, resolve
  # the same model_str again — Pools.resolve picks the next-best account
  # from the same pool. When every account is throttled we propagate the
  # error up honestly (no silent failover to a different pool).
  # `attempts_left` is the same global cap shared with `do_pool_stream` /
  # `do_pool_call`; once exhausted we stop without re-resolving (otherwise
  # a single-account pool whose endpoint persistently 5xx's would loop
  # infinitely, since `:server_error` doesn't trigger `mark_throttled`
  # and `Pools.resolve` keeps returning the same account).
  defp retry_after_rotation(model_str, _body, _reply_pid, _on_tokens, _mode, attempts_left)
       when attempts_left <= 0 do
    Logger.error("[LLM] global attempt cap reached during rotation, giving up #{model_str}")
    {:error, :attempts_exhausted}
  end

  defp retry_after_rotation(model_str, body, reply_pid, on_tokens, mode, attempts_left) do
    case Pools.resolve(model_str) do
      {:ok, fresh} ->
        adapter = adapter_for(fresh)
        case mode do
          :stream -> do_pool_stream(fresh, adapter, body, reply_pid, model_str, on_tokens, attempts_left)
          :call   -> do_pool_call(fresh, adapter, body, model_str, on_tokens, attempts_left)
        end

      {:error, :all_throttled, _ms} ->
        {:error, "all_keys_exhausted"}

      err ->
        err
    end
  end

  # ─── Body / response ───────────────────────────────────────────────────────

  # Inject pool-level options into the per-call options map. Right
  # now that's just `num_ctx`, which only matters for the Ollama
  # adapter — other protocols ignore the field. Caller-supplied
  # `:num_ctx` (rare but legal, e.g. a one-off long-context request)
  # always wins; pool-level only fills the blank.
  defp inject_pool_options(%{protocol: "ollama", num_ctx: ctx}, options)
       when is_integer(ctx) and ctx > 0 and is_map(options) do
    if Map.has_key?(options, :num_ctx) or Map.has_key?(options, "num_ctx") do
      options
    else
      Map.put(options, :num_ctx, ctx)
    end
  end

  defp inject_pool_options(_resolved, options), do: options

  defp parse_response(body, model_str, on_tokens, adapter) when is_map(body) do
    {tx, rx, msg} = adapter.extract_message(body)
    if on_tokens && (rx > 0 or tx > 0), do: on_tokens.(rx, tx)

    tool_calls  = msg["tool_calls"]
    raw_content = msg["content"] || ""

    # Unified thinking extraction: prefer dedicated field (Gemini), fall back to
    # stripping <think>...</think> from content (Qwen3 and others).
    {thinking, content} =
      case msg["thinking"] || msg["reasoning_content"] do
        t when is_binary(t) and t != "" -> {t, raw_content}
        _ -> extract_think_tags(raw_content)
      end

    if is_binary(thinking) and thinking != "" do
      Logger.debug("[LLM] thinking len=#{String.length(thinking)} #{model_str}: #{String.slice(thinking, 0, 200)}")
    end

    cond do
      is_list(tool_calls) and tool_calls != [] ->
        Logger.info("[LLM] call tool_calls=#{length(tool_calls)}")
        {:ok, {:tool_calls, normalize_tool_calls(tool_calls)}}

      true ->
        Logger.info("[LLM] call done chars=#{String.length(content)} #{model_str}")
        {:ok, content}
    end
  end

  defp parse_response(body, _model_str, _on_tokens, _adapter) do
    {:error, "Unexpected response: #{inspect(body, limit: 200)}"}
  end

  # Extract <think>...</think> blocks from content (Qwen3-style embedded thinking).
  # Returns {thinking_text, clean_content}.
  defp extract_think_tags(content) when is_binary(content) do
    thinking = Regex.scan(~r/<think>(.*?)<\/think>/s, content, capture: :all_but_first)
               |> List.flatten()
               |> Enum.join("\n")
    clean = Regex.replace(~r/<think>.*?<\/think>/s, content, "") |> String.trim()
    {if(thinking == "", do: nil, else: thinking), clean}
  end

  @doc false
  # Split a streaming content token into {think_part, content_part} by tracking
  # whether we're currently inside a <think>...</think> block across tokens.
  # Public (with @doc false) so wire-protocol adapters can reuse the same
  # state machine without re-implementing it. Not part of the stable API.
  def split_think_token(token, think_key, in_think_key) do
    combined = Process.get(think_key) <> token
    in_think = Process.get(in_think_key)

    {think_out, content_out, new_think_buf, new_in_think} =
      parse_think_stream(combined, in_think, "", "")

    Process.put(think_key, new_think_buf)
    Process.put(in_think_key, new_in_think)
    {think_out, content_out}
  end

  defp parse_think_stream(<<>>, in_think, think_acc, content_acc),
    do: {think_acc, content_acc, "", in_think}

  defp parse_think_stream(<<"<think>", rest::binary>>, false, think_acc, content_acc),
    do: parse_think_stream(rest, true, think_acc, content_acc)

  defp parse_think_stream(<<"</think>", rest::binary>>, true, think_acc, content_acc),
    do: parse_think_stream(rest, false, think_acc, content_acc)

  defp parse_think_stream(<<"<think", _::binary>> = buf, false, think_acc, content_acc),
    do: {think_acc, content_acc, buf, false}

  defp parse_think_stream(<<"</think", _::binary>> = buf, true, think_acc, content_acc),
    do: {think_acc, content_acc, buf, true}

  defp parse_think_stream(<<char::utf8, rest::binary>>, true, think_acc, content_acc),
    do: parse_think_stream(rest, true, think_acc <> <<char::utf8>>, content_acc)

  defp parse_think_stream(<<char::utf8, rest::binary>>, false, think_acc, content_acc),
    do: parse_think_stream(rest, false, think_acc, content_acc <> <<char::utf8>>)

  # ─── Tool call normalization ────────────────────────────────────────────────

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      # Preserve all fields the model returned in the function map, only decoding
      # `arguments` (which may arrive as a JSON string). Unknown fields (e.g.
      # Gemini's thought_signature) are kept intact so they can be echoed back in
      # conversation history without model-specific special cases.
      fn_map =
        (call["function"] || %{})
        |> Map.put("name",      get_in(call, ["function", "name"]) || "")
        |> Map.put("arguments", decode_args(get_in(call, ["function", "arguments"]) || %{}))

      call
      |> Map.put("id",       call["id"] || generate_id())
      |> Map.put("function", fn_map)
    end)
  end

  # ─── Ollama message sanitization ───────────────────────────────────────────

  # Gemini thinking-mode responses attach an internal `thought_signature` to each
  # function call.  Ollama's /api/chat format does not expose this field, so the
  # client can never echo it back.  When the history contains tool-call messages
  # from a previous thinking-mode turn, Gemini rejects the next request with
  # HTTP 400 "Function call is missing a thought_signature in functionCall parts."
  #
  # Fix: before sending to any Ollama endpoint, convert:
  #   assistant{tool_calls:[…]} → assistant{content:"[called tools: name1, name2]"}
  #   tool{content:…, tool_call_id:…} → user{content:"[tool result: name] …"}
  #
  # The model continues to understand the conversation from the text descriptions.
  # Verified by isolated HTTP replay test: stripping tool-call format from history
  # resolves the 400 while preserving model reasoning quality.
  # Only Gemini models (hosted via Ollama) have the thought_signature limitation.
  # Other models (Mistral, LLaMA, etc.) handle tool_call history natively — leave them unchanged.
  defp sanitize_messages("ollama", messages, model_name) do
    if String.contains?(String.downcase(model_name), "gemini") do
      do_sanitize_gemini_messages(messages)
    else
      messages
    end
  end

  defp sanitize_messages(_protocol, messages, _model_name), do: messages

  defp do_sanitize_gemini_messages(messages) do
    # Build a map from tool_call_id → full call, so the tool result message
    # can include both the name and the arguments for context.
    call_id_to_call =
      Enum.flat_map(messages, fn msg ->
        if (msg[:role] || msg["role"]) == "assistant" do
          (msg[:tool_calls] || msg["tool_calls"] || [])
          |> Enum.map(fn call -> {call["id"] || "", call} end)
        else
          []
        end
      end)
      |> Map.new()

    Enum.map(messages, fn msg ->
      role  = msg[:role]  || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      cond do
        role == "assistant" and is_list(calls) and calls != [] ->
          existing_content = msg[:content] || msg["content"] || ""
          parts = Enum.map(calls, fn c ->
            name = get_in(c, ["function", "name"]) || "?"
            args = decode_args(get_in(c, ["function", "arguments"]) || %{})
            args_str = Jason.encode!(args)
            "[used: #{name}(#{args_str})]"
          end)
          suffix = Enum.join(parts, " ")
          combined = if existing_content != "", do: "#{existing_content}\n#{suffix}", else: suffix
          %{role: "assistant", content: combined}

        role == "tool" ->
          content      = msg[:content] || msg["content"] || ""
          tool_call_id = msg[:tool_call_id] || msg["tool_call_id"] || ""
          call         = Map.get(call_id_to_call, tool_call_id, %{})
          name         = get_in(call, ["function", "name"]) || "tool"
          %{role: "user", content: "[result:#{name}] #{content}"}

        true ->
          msg
      end
    end)
  end

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, m} -> m
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  # ─── Helpers ───────────────────────────────────────────────────────────────

  defp do_stream_request(url, headers, body, reply_pid, model_str, on_tokens, adapter) do
    text_key    = {__MODULE__, :text,       self()}
    calls_key   = {__MODULE__, :calls,      self()}
    buf_key     = {__MODULE__, :buf,        self()}
    err_key     = {__MODULE__, :err,        self()}
    think_key   = {__MODULE__, :think_buf,  self()}
    in_think_key = {__MODULE__, :in_think,  self()}
    chunks_key  = {__MODULE__, :chunks,     self()}
    first_byte_key = {__MODULE__, :first_byte, self()}
    tc_acc_key  = {__MODULE__, :tc_acc,     self()}

    Process.put(text_key,     "")
    Process.put(calls_key,    [])
    Process.put(buf_key,      "")
    Process.put(think_key,    "")
    Process.put(in_think_key, false)
    Process.put(chunks_key,   0)
    Process.put(tc_acc_key,   %{})
    Process.delete(err_key)
    Process.delete(first_byte_key)

    body_size = body |> Jason.encode!() |> byte_size()
    req_id    = :erlang.unique_integer([:positive, :monotonic])
    t0        = System.monotonic_time(:millisecond)

    Logger.info("[LLM:http req=#{req_id}] stream BEGIN model=#{model_str} body_bytes=#{body_size} url=#{url}")
    DmhAi.SysLog.log("[LLM:http req=#{req_id}] stream BEGIN model=#{model_str} body_bytes=#{body_size}")

    # See do_call_request for why we force `Connection: close` +
    # `compressed: false` — first stops zombie-socket reuse; second
    # avoids a gzip-decoder stall on long streamed responses.
    headers_no_reuse = [{"connection", "close"} | headers]

    result =
      Req.post(url,
        json: body,
        headers: headers_no_reuse,
        compressed: false,
        receive_timeout: AgentSettings.llm_receive_timeout_ms(),
        retry: false,
        finch: DmhAi.Finch,
        into: fn {:data, data}, {req, resp} ->
          # Record first-byte latency once — the gap between BEGIN and first
          # chunk tells us whether Ollama / network is slow to START replying
          # vs slow while streaming.
          if is_nil(Process.get(first_byte_key)) do
            fb_ms = System.monotonic_time(:millisecond) - t0
            Process.put(first_byte_key, fb_ms)
            Logger.info("[LLM:http req=#{req_id}] stream FIRST_BYTE_MS=#{fb_ms}")
          end
          Process.put(chunks_key, Process.get(chunks_key) + 1)

          combined = Process.get(buf_key) <> data
          lines = String.split(combined, "\n")
          {complete, [leftover]} = Enum.split(lines, length(lines) - 1)
          Process.put(buf_key, leftover)

          ctx = %{
            text_key: text_key, calls_key: calls_key, err_key: err_key,
            think_key: think_key, in_think_key: in_think_key,
            tc_acc_key: tc_acc_key,
            reply_pid: reply_pid, on_tokens: on_tokens
          }

          halt? =
            Enum.reduce_while(complete, false, fn line, _ ->
              line = String.trim(line)
              cond do
                line == "" -> {:cont, false}
                true       -> adapter.handle_stream_line(line, ctx)
              end
            end)

          if halt?, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
        end
      )

    # Post-stream consolidation. OpenAI fragments tool_calls across
    # chunks and needs the accumulator collapsed into a list; Ollama-
    # native delivers complete tool_call objects per line and is a
    # no-op. Adapter decides.
    adapter.finalize_stream(%{
      text_key: text_key, calls_key: calls_key, err_key: err_key,
      think_key: think_key, in_think_key: in_think_key,
      tc_acc_key: tc_acc_key,
      reply_pid: reply_pid, on_tokens: on_tokens
    })

    stream_err   = Process.get(err_key)
    full_text    = Process.get(text_key)
    tool_calls   = Process.get(calls_key)
    chunks_count = Process.get(chunks_key) || 0
    first_byte   = Process.get(first_byte_key)
    Process.delete(text_key)
    Process.delete(calls_key)
    Process.delete(tc_acc_key)
    Process.delete(buf_key)
    Process.delete(err_key)
    Process.delete(chunks_key)
    Process.delete(first_byte_key)

    t_end    = System.monotonic_time(:millisecond)
    elapsed  = t_end - t0
    req_summary = "[LLM:http req=#{req_id}] stream END total_ms=#{elapsed} first_byte_ms=#{inspect(first_byte)} chunks=#{chunks_count} text_chars=#{String.length(full_text)} tool_calls=#{length(tool_calls)} err=#{inspect(stream_err)}"
    Logger.info(req_summary)
    DmhAi.SysLog.log(req_summary)

    cond do
      stream_err != nil ->
        # Inline error in NDJSON — classify conservatively. ONLY treat as
        # `:rate_limited` when the text genuinely signals rate-limiting.
        # Previously any non-"weekly usage limit" inline error was
        # classified as rate-limit — that caused request-format errors
        # (e.g. "Expected last role User or Tool … got assistant") to
        # throttle the account, and rotation hit the same format error
        # on every subsequent key, locking the whole pool within a few
        # requests. Unknown errors now propagate as a plain string —
        # rotation's `other -> other` fall-through passes them up
        # WITHOUT throttling the account.
        err_text = to_string(stream_err)
        cond do
          String.contains?(err_text, "weekly usage limit") ->
            {:error, :quota_exhausted}

          looks_like_rate_limit?(err_text) ->
            {:error, :rate_limited}

          # Transient server-side overload — Ollama Cloud sometimes
          # ships these as inline NDJSON errors on a 200-OK stream
          # (the connection was already established when the upstream
          # model lookup hit overload). Map to :server_error so the
          # do_pool_stream retry-then-rotate logic kicks in, same as
          # for an HTTP 5xx response.
          looks_like_server_error?(err_text) ->
            {:error, :server_error}

          true ->
            {:error, "stream error: #{err_text}"}
        end

      match?({:ok, %{status: s}} when s not in [200], result) ->
        {:ok, resp} = result
        status = resp.status
        Logger.error("[LLM] stream HTTP #{status} #{model_str}")
        cond do
          status == 429 -> rate_limited_error(resp)
          status >= 500 -> {:error, :server_error}
          true          -> {:error, "HTTP #{status}"}
        end

      match?({:ok, _}, result) ->
        if tool_calls != [] do
          Logger.info("[LLM] stream tool_calls=#{length(tool_calls)}")
          {:ok, {:tool_calls, normalize_tool_calls(tool_calls)}}
        else
          Logger.info("[LLM] stream done chars=#{String.length(full_text)}")
          {:ok, full_text}
        end

      true ->
        {:error, reason} = result
        Logger.error("[LLM] stream failed #{model_str}: #{inspect(reason)}")
        # Same transport-error classification as do_call_request — lets
        # do_cloud_stream's retry+rotate kick in on timeout / closed.
        classify_transport_error(reason)
    end
  end

  defp do_call_request(url, headers, body, model_str, on_tokens, adapter) when is_atom(adapter) do
    # ── HTTP-path instrumentation (diagnostics for outbound call hangs) ──
    # Wraps Req.post with monotonic-time stamps around every boundary so we
    # can see exactly where a slow call is spending its time:
    #   t0  request prepared (body serialised below via Req's :json opt)
    #   t1  Req.post returns (connection acquired, request sent, response
    #       fully received → only blocks on network)
    #   t2  response body parsed, final tuple returned
    body_size = body |> Jason.encode!() |> byte_size()
    req_id    = :erlang.unique_integer([:positive, :monotonic])
    t0        = System.monotonic_time(:millisecond)

    Logger.info("[LLM:http req=#{req_id}] call BEGIN model=#{model_str} body_bytes=#{body_size} url=#{url}")
    DmhAi.SysLog.log("[LLM:http req=#{req_id}] call BEGIN model=#{model_str} body_bytes=#{body_size}")

    # `Connection: close` + `compressed: false` + bounded receive_timeout:
    # three guardrails learned from production incidents against Ollama
    # Cloud. `Connection: close` forces fresh TCP/TLS per call — immune
    # to zombie-socket reuse. `compressed: false` disables the default
    # `Accept-Encoding: gzip` header — without it, Ollama's edge sometimes
    # returns a gzipped response whose incremental decoding stalls on
    # long text generations (short tool-call responses fit in one packet
    # and always decoded cleanly; only multi-packet text responses
    # triggered the hang). receive_timeout caps any individual call
    # via `AgentSettings.llm_receive_timeout_ms` so unknown future
    # stalls still fail out rather than block forever.
    # See specs/architecture.md §Outbound HTTP for LLM calls.
    headers_no_reuse = [{"connection", "close"} | headers]

    req_result =
      Req.post(url,
        json: body,
        headers: headers_no_reuse,
        compressed: false,
        receive_timeout: AgentSettings.llm_receive_timeout_ms(),
        retry: false,
        finch: DmhAi.Finch
      )

    t1       = System.monotonic_time(:millisecond)
    elapsed1 = t1 - t0

    case req_result do
      {:ok, %{status: 200, body: resp_body}} ->
        resp_size =
          case resp_body do
            m when is_map(m) or is_list(m) -> m |> Jason.encode!() |> byte_size()
            b when is_binary(b)            -> byte_size(b)
            _                              -> 0
          end
        Logger.info("[LLM:http req=#{req_id}] call OK status=200 network_ms=#{elapsed1} resp_bytes=#{resp_size}")
        result = parse_response(resp_body, model_str, on_tokens, adapter)
        t2 = System.monotonic_time(:millisecond)
        Logger.info("[LLM:http req=#{req_id}] call DONE parse_ms=#{t2 - t1} total_ms=#{t2 - t0}")
        result

      {:ok, %{status: 429, body: resp_body} = resp} ->
        err_msg = get_in(resp_body, ["error"]) || ""
        Logger.warning("[LLM:http req=#{req_id}] call 429 elapsed_ms=#{elapsed1} model=#{model_str}: #{inspect(resp_body)}")
        if String.contains?(to_string(err_msg), "weekly usage limit") do
          {:error, :quota_exhausted}
        else
          rate_limited_error(resp)
        end

      {:ok, %{status: status, body: resp_body}} when status >= 500 ->
        Logger.error("[LLM:http req=#{req_id}] call HTTP #{status} elapsed_ms=#{elapsed1} #{model_str}: #{inspect(resp_body)}")
        {:error, :server_error}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[LLM:http req=#{req_id}] call HTTP #{status} elapsed_ms=#{elapsed1} #{model_str}: #{inspect(resp_body)}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("[LLM:http req=#{req_id}] call FAILED elapsed_ms=#{elapsed1} model=#{model_str}: #{inspect(reason)}")
        # Classify transport-layer errors (timeout, connection closed,
        # DNS failure, …) as :server_error so do_cloud_call's retry +
        # account rotation kicks in. Otherwise the raw Req error
        # struct would propagate up to the session loop and be persisted
        # verbatim as the assistant message ("LLM error: %Req.Transport
        # Error{...}") — ugly and wastes the turn.
        classify_transport_error(reason)
    end
  end

  # Transport-layer errors get classified as :server_error so the outer
  # account-rotation retry takes over. Recognises both Req's and Mint's
  # error structs (Req.TransportError wraps Mint.TransportError).
  defp classify_transport_error(%Req.TransportError{}), do: {:error, :server_error}
  defp classify_transport_error(%Mint.TransportError{}), do: {:error, :server_error}
  defp classify_transport_error(%{reason: reason})
       when reason in [:timeout, :closed, :econnrefused, :econnreset, :nxdomain],
       do: {:error, :server_error}
  defp classify_transport_error(other), do: {:error, other}

  # Extract a rate-limit error tuple, preferring a server-supplied
  # `Retry-After` header when present so we can throttle exactly as
  # long as the provider asked us to — not a blanket constant. Falls
  # back to `:rate_limited` atom (caller uses the configurable
  # default from `AgentSettings.rate_limit_throttle_secs/0`).
  defp rate_limited_error(%_{headers: headers}) do
    case parse_retry_after_ms(headers) do
      nil -> {:error, :rate_limited}
      ms  -> {:error, {:rate_limited, ms}}
    end
  end
  defp rate_limited_error(_), do: {:error, :rate_limited}

  # Parse `Retry-After` from Req's `headers` map (string keys →
  # list-of-string values). Supports the integer-seconds form only
  # (e.g. `"30"`, `"120"`). HTTP-date form (`"Wed, 21 Oct 2015
  # 07:28:00 GMT"`) and malformed values return nil — caller falls
  # back to the configured default.
  defp parse_retry_after_ms(%{} = headers) do
    # Req normalises header names to lowercase.
    case Map.get(headers, "retry-after") do
      [value | _] when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {secs, ""} when secs > 0 and secs <= 3600 -> secs * 1000
          _                                         -> nil
        end

      _ -> nil
    end
  end
  defp parse_retry_after_ms(_), do: nil

  # Conservative rate-limit marker check. Upstreams vary: Ollama cloud
  # says "rate limit" / "too many requests"; OpenAI says "rate limit
  # reached" / "Too Many Requests"; Anthropic says "rate_limit_error"
  # or "quota". Match on lowercased substring so a surprising casing
  # doesn't slip past. Anything that matches NONE of these markers is
  # treated as an unknown error and propagates up WITHOUT throttling
  # the account — rotating keys doesn't fix a malformed request.
  @rate_limit_markers [
    "rate limit", "rate_limit", "rate-limit",
    "too many requests",
    "quota", "throttle", "slow down", "try again in"
  ]

  defp looks_like_rate_limit?(text) when is_binary(text) do
    lower = String.downcase(text)
    Enum.any?(@rate_limit_markers, &String.contains?(lower, &1))
  end
  defp looks_like_rate_limit?(_), do: false

  # Transient server-overload markers that arrive as inline NDJSON
  # errors. Distinct from rate-limit markers — these mean "upstream
  # is fine, just try again", not "this account hit a quota".
  @server_error_markers [
    "overloaded", "service unavailable", "temporarily unavailable",
    "internal server error", "internal error",
    "retry shortly", "try again shortly",
    "503", "502", "504"
  ]

  # Public for testability — the markers list is the load-bearing
  # piece, separate test in itgr_llm_classifier.exs.
  @doc false
  def looks_like_server_error?(text) when is_binary(text) do
    lower = String.downcase(text)
    Enum.any?(@server_error_markers, &String.contains?(lower, &1))
  end
  def looks_like_server_error?(_), do: false

  defp generate_id, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  # ─── Log helpers ───────────────────────────────────────────────────────────

  defp log_messages(messages) do
    non_sys = Enum.reject(messages, fn m -> (m[:role] || m["role"]) == "system" end)
    parts = Enum.map(non_sys, fn m ->
      role    = m[:role]       || m["role"]       || "?"
      content = m[:content]    || m["content"]    || ""
      calls   = m[:tool_calls] || m["tool_calls"] || []
      if is_list(calls) and calls != [] do
        names = Enum.map_join(calls, ",", fn c -> get_in(c, ["function", "name"]) || "?" end)
        "[#{role}→#{names}]"
      else
        snippet = content |> to_string() |> String.slice(0, 100) |> String.replace("\n", "↵")
        "[#{role}]#{snippet}"
      end
    end)
    result = Enum.join(parts, " | ")
    if String.length(result) > 1000, do: String.slice(result, 0, 1000) <> "…", else: result
  end

  defp maybe_trace(nil, _model_str, _messages, _tools, _result), do: :ok
  defp maybe_trace(meta, model_str, messages, tools, result) do
    if AgentSettings.log_trace() do
      LogTrace.write(meta, model_str, messages, tools, result)
    end
  end

end
