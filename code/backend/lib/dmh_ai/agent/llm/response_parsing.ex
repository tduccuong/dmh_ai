# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.LLM.ResponseParsing do
  @moduledoc """
  Body-parsing + tool-call normalisation + think-tag extraction shared
  by both the streaming and non-streaming paths in `DmhAi.Agent.LLM`.

  Public surface used outside this module:

    * `parse_response/4` — non-stream JSON response → `{:ok, text}` or
      `{:ok, {:tool_calls, calls}}` or `{:error, reason}`.
    * `safe_normalize_tool_calls/1` — wrap `normalize_tool_calls/1` so
      a malformed-arguments raise becomes a typed error envelope.
    * `normalize_tool_calls/1` — decode each call's JSON `arguments`,
      fill `id` if missing, preserve unknown fields (Gemini's
      `thought_signature` etc.).
    * `decode_args/1` — the load-bearing JSON decoder; raises
      `MalformedArgumentsError` on a corrupted stream.
    * `split_think_token/3` — streaming `<think>…</think>` state
      machine. Used by the per-protocol adapters.
    * `extract_think_tags/1` — non-stream variant: pull all
      `<think>…</think>` blocks out of a complete content string.
  """

  alias DmhAi.Agent.LLM.Logging
  require Logger

  def parse_response(body, model_str, on_tokens, adapter) when is_map(body) do
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
        safe_normalize_tool_calls(tool_calls)

      true ->
        Logger.info("[LLM] call done chars=#{String.length(content)} #{model_str}")
        {:ok, content}
    end
  end

  def parse_response(body, _model_str, _on_tokens, _adapter) do
    {:error, "Unexpected response: #{inspect(body, limit: 200)}"}
  end

  # Wraps `normalize_tool_calls/1` so a malformed-arguments raise is
  # converted to a typed error envelope the chain handler can surface
  # to the user honestly. We intentionally do NOT swallow this — it's a
  # harness or model defect that retrying won't fix.
  def safe_normalize_tool_calls(calls) do
    {:ok, {:tool_calls, normalize_tool_calls(calls)}}
  rescue
    e in DmhAi.LLM.MalformedArgumentsError ->
      {:error, {:arguments_decode_failed, e.raw}}
  end

  # ─── Tool call normalization ────────────────────────────────────────────────

  def normalize_tool_calls(calls) when is_list(calls) do
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
      |> Map.put("id",       call["id"] || Logging.generate_id())
      |> Map.put("function", fn_map)
    end)
  end

  # Decode a tool-call's `arguments` field.
  #
  # The streaming accumulator builds this field by concatenating
  # `function.arguments` fragments — the result MUST parse as a JSON
  # object. A failure means either the model emitted malformed JSON
  # (rare; usually a real model bug) or the harness corrupted the
  # stream (e.g. an accumulator merging two distinct tool calls into
  # one slot). Either way the silent fallback `%{}` masks the bug and
  # routes blame to a downstream "missing required field" check.
  #
  # Fail loud: log the raw string plus the decode error to syslog and
  # raise. The streaming pipeline unwinds and the user sees an honest
  # internal-error message rather than a confusing model-correction
  # loop.
  def decode_args(args) when is_map(args), do: args

  def decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, m} when is_map(m) ->
        m

      other ->
        snippet = String.slice(args, 0, 500)

        Logger.error(
          "[LLM] tool_call.arguments failed to decode as JSON object. " <>
            "raw=#{inspect(snippet)} decode=#{inspect(other)}"
        )

        DmhAi.SysLog.log(
          "[CRITICAL] LLM tool_call.arguments_decode_failed " <>
            "raw_len=#{byte_size(args)} raw=#{snippet}"
        )

        raise DmhAi.LLM.MalformedArgumentsError, raw: args, decode_error: other
    end
  end

  def decode_args(_), do: %{}

  # Extract <think>...</think> blocks from content (Qwen3-style embedded thinking).
  # Returns {thinking_text, clean_content}.
  def extract_think_tags(content) when is_binary(content) do
    thinking = Regex.scan(~r/<think>(.*?)<\/think>/s, content, capture: :all_but_first)
               |> List.flatten()
               |> Enum.join("\n")
    clean = Regex.replace(~r/<think>.*?<\/think>/s, content, "") |> String.trim()
    {if(thinking == "", do: nil, else: thinking), clean}
  end

  # Split a streaming content token into {think_part, content_part} by tracking
  # whether we're currently inside a <think>...</think> block across tokens.
  # Used by per-protocol stream adapters; the state lives in two process-dict
  # keys (`think_key` and `in_think_key`) so the caller doesn't have to thread
  # buffers through the streaming-line callback.
  def split_think_token(token, think_key, in_think_key) do
    combined = Process.get(think_key) <> token
    in_think = Process.get(in_think_key)

    {think_out, content_out, new_think_buf, new_in_think} =
      parse_think_stream(combined, in_think, "", "")

    Process.put(think_key, new_think_buf)
    Process.put(in_think_key, new_in_think)
    {think_out, content_out}
  end

  def parse_think_stream(<<>>, in_think, think_acc, content_acc),
    do: {think_acc, content_acc, "", in_think}

  def parse_think_stream(<<"<think>", rest::binary>>, false, think_acc, content_acc),
    do: parse_think_stream(rest, true, think_acc, content_acc)

  def parse_think_stream(<<"</think>", rest::binary>>, true, think_acc, content_acc),
    do: parse_think_stream(rest, false, think_acc, content_acc)

  def parse_think_stream(<<"<think", _::binary>> = buf, false, think_acc, content_acc),
    do: {think_acc, content_acc, buf, false}

  def parse_think_stream(<<"</think", _::binary>> = buf, true, think_acc, content_acc),
    do: {think_acc, content_acc, buf, true}

  def parse_think_stream(<<char::utf8, rest::binary>>, true, think_acc, content_acc),
    do: parse_think_stream(rest, true, think_acc <> <<char::utf8>>, content_acc)

  def parse_think_stream(<<char::utf8, rest::binary>>, false, think_acc, content_acc),
    do: parse_think_stream(rest, false, think_acc, content_acc <> <<char::utf8>>)
end
