# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.LLM.PoolRequest do
  @moduledoc """
  Pool-driven retry + account-rotation wrapper around `HttpClient`.

  On a per-account failure (`:rate_limited`, `:quota_exhausted`, or a
  persistent `:server_error` after the within-account retry budget)
  this layer marks the account throttled via
  `AccountRotation.mark_throttled/3` and re-runs `Pools.resolve/1` to
  pick the next-best account in the same pool. The whole sequence
  is bounded by a global `attempts_left` cap shared with
  `retry_after_rotation/6` so a single-account pool that persistently
  5xx's can't loop forever.

  Public surface used by the shell:

    * `do_pool_stream/8` — streaming entry; threads
      `(resolved, adapter, body, reply_pid, model_str, on_tokens,
        attempts_left, retries)`.
    * `do_pool_call/7` — non-streaming entry; same shape minus
      `reply_pid`.
    * `auth_headers/1` — protocol-aware auth header list (Bearer for
      OpenAI/Ollama, x-api-key + anthropic-version for Anthropic).
    * `inject_pool_options/2` — fold pool-level options (currently
      just `num_ctx` for Ollama) into the per-call options map.
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Agent.LLM
  alias DmhAi.Agent.LLM.HttpClient
  alias DmhAi.LLM.{AccountRotation, Pools}
  require Logger

  # Transient-error retry budget for a single account before rotation
  # kicks in. Three retries with @server_error_delay_ms backoff = ~6s
  # total before we mark the account throttled and pick the next one.
  # Bounded by `AgentSettings.llm_total_attempts/0` (the global cap
  # across within-account retries + cross-account rotation cycles —
  # see arch_wiki §Retry cap).
  @server_error_retries 3
  @server_error_delay_ms 2_000

  # Protocol-specific auth headers. OpenAI/Ollama take a Bearer token;
  # Anthropic rejects Bearer and requires `x-api-key` + the
  # `anthropic-version` header. Pools without an api_key (LAN dev
  # endpoints, no-auth shims) get an empty list.
  def auth_headers(%{protocol: "anthropic", api_key: key}),
    do: DmhAi.LLM.Adapters.Anthropic.auth_headers(key)

  def auth_headers(%{api_key: key}) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer " <> key}]

  def auth_headers(_), do: []

  # Streaming wrapper with per-account fallback. On rate-limit / quota
  # exhaust against the chosen account, marks it throttled (persisted via
  # AccountRotation) and resolves a fresh account from the same pool.
  # `attempts_left` is the global cap (default
  # `AgentSettings.llm_total_attempts/0`) shared with cross-account
  # rotation in `retry_after_rotation`. Each Req.post attempt
  # decrements it; reaching 0 returns `{:error, :attempts_exhausted}`.
  def do_pool_stream(resolved, adapter, body, reply_pid, model_str, on_tokens, attempts_left, retries \\ @server_error_retries)

  def do_pool_stream(_resolved, _adapter, _body, _reply_pid, model_str, _on_tokens, attempts_left, _retries)
      when attempts_left <= 0 do
    Logger.error("[LLM] global attempt cap reached, giving up #{model_str}")
    {:error, :attempts_exhausted}
  end

  def do_pool_stream(resolved, adapter, body, reply_pid, model_str, on_tokens, attempts_left, retries) do
    url     = adapter.chat_endpoint_url(resolved)
    headers = auth_headers(resolved)
    attempts_left = attempts_left - 1

    case HttpClient.do_stream_request(url, headers, body, reply_pid, model_str, on_tokens, adapter) do
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
  def do_pool_call(resolved, adapter, body, model_str, on_tokens, attempts_left, retries \\ @server_error_retries)

  def do_pool_call(_resolved, _adapter, _body, model_str, _on_tokens, attempts_left, _retries)
      when attempts_left <= 0 do
    Logger.error("[LLM] global attempt cap reached, giving up #{model_str}")
    {:error, :attempts_exhausted}
  end

  def do_pool_call(resolved, adapter, body, model_str, on_tokens, attempts_left, retries) do
    url     = adapter.chat_endpoint_url(resolved)
    headers = auth_headers(resolved)
    attempts_left = attempts_left - 1

    case HttpClient.do_call_request(url, headers, body, model_str, on_tokens, adapter) do
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
        adapter = LLM.adapter_for(fresh)
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

  # Inject pool-level options into the per-call options map. Right
  # now that's just `num_ctx`, which only matters for the Ollama
  # adapter — other protocols ignore the field. Caller-supplied
  # `:num_ctx` (rare but legal, e.g. a one-off long-context request)
  # always wins; pool-level only fills the blank.
  def inject_pool_options(%{protocol: "ollama", num_ctx: ctx}, options)
      when is_integer(ctx) and ctx > 0 and is_map(options) do
    if Map.has_key?(options, :num_ctx) or Map.has_key?(options, "num_ctx") do
      options
    else
      Map.put(options, :num_ctx, ctx)
    end
  end

  def inject_pool_options(_resolved, options), do: options
end
