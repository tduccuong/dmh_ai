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

  ## Shape

  This module is a thin shell over the per-concern helpers that live
  under `__MODULE__.{PoolRequest, HttpClient, ResponseParsing,
  Messages, Errors, Logging}`. The shell owns the public API
  (`stream/4` + `call/3`), the wire-protocol adapter dispatch
  (`adapter_for/1`), and a small set of `defdelegate`s for functions
  that conceptually moved to a sub-module but were already part of
  the module's public surface.
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.LLM.Pools
  alias __MODULE__.{PoolRequest, Messages, Logging, ResponseParsing, Errors}
  require Logger

  # ─── Wire-protocol adapter dispatch ────────────────────────────────────────
  #
  # The adapter encapsulates everything that differs between wire
  # protocols: endpoint URL, request body shape, response parsing,
  # streaming line parser, and post-stream consolidation. The rest
  # (account rotation, retry-on-throttle, transport timing,
  # thinking-tag extraction, message sanitisation) stays in the
  # sibling modules.
  #
  # Dispatch is protocol-driven and fail-loud — every pool declares
  # its wire protocol at create time and the resolver carries that
  # value through unchanged. An unknown value here is a bug in
  # `Pools.create/1` validation, not a runtime fallback target.
  #
  # Public-but-`@doc false` so the post-rotation re-resolution in
  # `PoolRequest.retry_after_rotation` can dispatch on the freshly
  # resolved account without circular-aliasing back into the shell.
  @doc false
  def adapter_for(%{protocol: "openai"}),    do: DmhAi.LLM.Adapters.OpenAI
  def adapter_for(%{protocol: "ollama"}),    do: DmhAi.LLM.Adapters.Ollama
  def adapter_for(%{protocol: "anthropic"}), do: DmhAi.LLM.Adapters.Anthropic

  def adapter_for(%{protocol: other}) do
    raise ArgumentError,
          "unknown pool protocol #{inspect(other)} — Pools validation should " <>
            "have rejected this. Allowed: #{inspect(DmhAi.LLM.Pools.valid_protocols())}"
  end

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
      trace       = Keyword.get(opts, :trace)
      on_tokens   = Keyword.get(opts, :on_tokens) || Logging.auto_token_tracker(trace)
      Logger.info("[LLM] stream #{model_str} msgs=#{length(messages)} tools=#{length(tools)}")
      DmhAi.SysLog.log("[LLM] stream model=#{model_str} msgs=#{length(messages)} tools=#{length(tools)}\n  #{Logging.log_messages(messages)}")

      result =
        case Pools.resolve(model_str) do
          {:ok, resolved} ->
            adapter = adapter_for(resolved)
            sanitized =
              Messages.sanitize_messages(resolved.protocol, messages, resolved.model)
              |> adapter.normalize_messages()
            options = PoolRequest.inject_pool_options(resolved, llm_options)
            body = adapter.build_body(resolved.model, sanitized, tools, true, options)
            PoolRequest.do_pool_stream(resolved, adapter, body, reply_pid, model_str, on_tokens,
                                       AgentSettings.llm_total_attempts())

          {:error, :all_throttled, retry_ms} ->
            Logger.error("[LLM] all accounts throttled in pool, retry in #{retry_ms}ms #{model_str}")
            {:error, :rate_limited}

          {:error, :unknown_pool} ->
            {:error, "unknown pool in model string: #{inspect(model_str)}"}

          {:error, :invalid_format} ->
            {:error, "invalid model format: #{inspect(model_str)} (expected <pool>::<model>)"}
        end

      Logging.maybe_trace(trace, model_str, messages, tools, result)
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
      trace       = Keyword.get(opts, :trace)
      on_tokens   = Keyword.get(opts, :on_tokens) || Logging.auto_token_tracker(trace)
      Logger.info("[LLM] call #{model_str} msgs=#{length(messages)} tools=#{length(tools)}")
      DmhAi.SysLog.log("[LLM] call model=#{model_str} msgs=#{length(messages)} tools=#{length(tools)}\n  #{Logging.log_messages(messages)}")

      result =
        case Pools.resolve(model_str) do
          {:ok, resolved} ->
            adapter = adapter_for(resolved)
            sanitized =
              Messages.sanitize_messages(resolved.protocol, messages, resolved.model)
              |> adapter.normalize_messages()
            options = PoolRequest.inject_pool_options(resolved, llm_options)
            body = adapter.build_body(resolved.model, sanitized, tools, false, options)
            PoolRequest.do_pool_call(resolved, adapter, body, model_str, on_tokens,
                                     AgentSettings.llm_total_attempts())

          {:error, :all_throttled, retry_ms} ->
            Logger.error("[LLM] all accounts throttled in pool, retry in #{retry_ms}ms #{model_str}")
            {:error, :rate_limited}

          {:error, :unknown_pool} ->
            {:error, "unknown pool in model string: #{inspect(model_str)}"}

          {:error, :invalid_format} ->
            {:error, "invalid model format: #{inspect(model_str)} (expected <pool>::<model>)"}
        end

      Logging.maybe_trace(trace, model_str, messages, tools, result)
      result
    end
  end

  # Test-only entry point — exposes the private `normalize_tool_calls`
  # pipeline so the streaming-accumulator regression tests can verify
  # both the happy path AND the malformed-arguments raise without
  # going through the full stream/decode plumbing.
  @doc false
  def __test_normalize_tool_calls__(calls), do: ResponseParsing.normalize_tool_calls(calls)

  # Streaming `<think>…</think>` state machine. Public (with @doc
  # false) so wire-protocol adapters can reuse the same state machine
  # without re-implementing it. Not part of the stable API.
  @doc false
  defdelegate split_think_token(token, think_key, in_think_key), to: ResponseParsing

  # Public for testability — the markers list is the load-bearing
  # piece, separate test in itgr_llm_classifier.exs.
  @doc false
  defdelegate looks_like_server_error?(text), to: Errors
end
