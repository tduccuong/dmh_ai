# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.LLM.HttpClient do
  @moduledoc """
  Raw single-request HTTP layer for `DmhAi.Agent.LLM`. Owns one
  Req.post per call, the per-request instrumentation, transport-error
  classification, and the test-hook seam that lets a flow stub a
  per-account response without touching the rotation logic above it.

  Two entry points mirror the public API:

    * `do_stream_request/7` — streaming `into:` callback drives the
      per-protocol `handle_stream_line/2` + post-stream
      `finalize_stream/1` hooks; consumes process-dict accumulators
      keyed by `self()`. Returns the same shape as a non-stream call.
    * `do_call_request/6` — single JSON request/response; delegates
      body parsing to `ResponseParsing.parse_response/4`.

  Errors classified here:

    * HTTP 429 → `{:error, {:rate_limited, ms}}` or `:rate_limited`
    * HTTP 5xx → `:server_error`
    * Transport errors (timeout / closed / DNS) → `:server_error`
    * Inline NDJSON `weekly usage limit` → `:quota_exhausted`
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Agent.LLM.{Errors, ResponseParsing}
  require Logger

  def do_stream_request(url, headers, body, reply_pid, model_str, on_tokens, adapter) do
    # Test hook (one layer DEEPER than `__llm_stream_stub__`). Lets a
    # test fake a per-account HTTP response so the rotation/retry
    # logic in `PoolRequest.do_pool_stream/8` actually runs. Stub fn:
    #   `(url, headers, body, %{kind: :stream, model: model_str,
    #      reply_pid: pid, on_tokens: on_tokens, adapter: atom}) ->
    #      {:ok, term} | {:error, atom} | {:error, {atom, term}}`
    # — same shape `do_stream_request` itself returns, so the
    # rotation logic can't tell the stub apart from a real
    # provider response.
    case Application.get_env(:dmh_ai, :__llm_request_stub__) do
      stub when is_function(stub, 4) ->
        stub.(url, headers, body, %{
          kind:      :stream,
          model:     model_str,
          reply_pid: reply_pid,
          on_tokens: on_tokens,
          adapter:   adapter
        })

      _ ->
        do_stream_request_live(url, headers, body, reply_pid, model_str, on_tokens, adapter)
    end
  end

  defp do_stream_request_live(url, headers, body, reply_pid, model_str, on_tokens, adapter) do
    text_key    = {DmhAi.Agent.LLM, :text,       self()}
    calls_key   = {DmhAi.Agent.LLM, :calls,      self()}
    buf_key     = {DmhAi.Agent.LLM, :buf,        self()}
    err_key     = {DmhAi.Agent.LLM, :err,        self()}
    think_key   = {DmhAi.Agent.LLM, :think_buf,  self()}
    in_think_key = {DmhAi.Agent.LLM, :in_think,  self()}
    chunks_key  = {DmhAi.Agent.LLM, :chunks,     self()}
    first_byte_key = {DmhAi.Agent.LLM, :first_byte, self()}
    tc_acc_key  = {DmhAi.Agent.LLM, :tc_acc,     self()}

    Process.put(text_key,     "")
    Process.put(calls_key,    [])
    Process.put(buf_key,      "")
    Process.put(think_key,    "")
    Process.put(in_think_key, false)
    Process.put(chunks_key,   0)
    # Each adapter owns the SHAPE of `tc_acc_key` (anthropic uses a flat
    # `%{idx => entry}` map; openai uses `%{by_key, order, last}`).
    # Reset by deleting — let the adapter initialise on first write.
    Process.delete(tc_acc_key)
    Process.delete(err_key)
    Process.delete(first_byte_key)

    body_size = body |> Jason.encode!() |> byte_size()
    req_id    = :erlang.unique_integer([:positive, :monotonic])
    t0        = System.monotonic_time(:millisecond)

    Logger.info("[LLM:http req=#{req_id}] stream BEGIN model=#{model_str} body_bytes=#{body_size} url=#{url}")
    DmhAi.SysLog.log("[LLM:http req=#{req_id}] stream BEGIN model=#{model_str} body_bytes=#{body_size}")

    # See do_call_request_live for why we force `Connection: close` +
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

          Errors.looks_like_rate_limit?(err_text) ->
            {:error, :rate_limited}

          # Transient server-side overload — Ollama Cloud sometimes
          # ships these as inline NDJSON errors on a 200-OK stream
          # (the connection was already established when the upstream
          # model lookup hit overload). Map to :server_error so the
          # do_pool_stream retry-then-rotate logic kicks in, same as
          # for an HTTP 5xx response.
          Errors.looks_like_server_error?(err_text) ->
            {:error, :server_error}

          true ->
            {:error, "stream error: #{err_text}"}
        end

      match?({:ok, %{status: s}} when s not in [200], result) ->
        {:ok, resp} = result
        status = resp.status
        Logger.error("[LLM] stream HTTP #{status} #{model_str}")
        cond do
          status == 429 -> Errors.rate_limited_error(resp)
          status >= 500 -> {:error, :server_error}
          true          -> {:error, "HTTP #{status}"}
        end

      match?({:ok, _}, result) ->
        if tool_calls != [] do
          Logger.info("[LLM] stream tool_calls=#{length(tool_calls)}")
          ResponseParsing.safe_normalize_tool_calls(tool_calls)
        else
          Logger.info("[LLM] stream done chars=#{String.length(full_text)}")
          {:ok, full_text}
        end

      true ->
        {:error, reason} = result
        Logger.error("[LLM] stream failed #{model_str}: #{inspect(reason)}")
        # Same transport-error classification as do_call_request — lets
        # the pool-level retry+rotate kick in on timeout / closed.
        classify_transport_error(reason)
    end
  end

  def do_call_request(url, headers, body, model_str, on_tokens, adapter) when is_atom(adapter) do
    # See `do_stream_request` for the rationale on this hook —
    # tests use it to fake per-account HTTP responses so rotation
    # logic exercises against deterministic transport outcomes.
    case Application.get_env(:dmh_ai, :__llm_request_stub__) do
      stub when is_function(stub, 4) ->
        stub.(url, headers, body, %{
          kind:      :call,
          model:     model_str,
          on_tokens: on_tokens,
          adapter:   adapter
        })

      _ ->
        do_call_request_live(url, headers, body, model_str, on_tokens, adapter)
    end
  end

  defp do_call_request_live(url, headers, body, model_str, on_tokens, adapter) when is_atom(adapter) do
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
        result = ResponseParsing.parse_response(resp_body, model_str, on_tokens, adapter)
        t2 = System.monotonic_time(:millisecond)
        Logger.info("[LLM:http req=#{req_id}] call DONE parse_ms=#{t2 - t1} total_ms=#{t2 - t0}")
        result

      {:ok, %{status: 429, body: resp_body} = resp} ->
        err_msg = get_in(resp_body, ["error"]) || ""
        Logger.warning("[LLM:http req=#{req_id}] call 429 elapsed_ms=#{elapsed1} model=#{model_str}: #{inspect(resp_body)}")
        if String.contains?(to_string(err_msg), "weekly usage limit") do
          {:error, :quota_exhausted}
        else
          Errors.rate_limited_error(resp)
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
        # DNS failure, …) as :server_error so the pool-level retry +
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
  def classify_transport_error(%Req.TransportError{}), do: {:error, :server_error}
  def classify_transport_error(%Mint.TransportError{}), do: {:error, :server_error}
  def classify_transport_error(%{reason: reason})
      when reason in [:timeout, :closed, :econnrefused, :econnreset, :nxdomain],
      do: {:error, :server_error}
  def classify_transport_error(other), do: {:error, other}
end
