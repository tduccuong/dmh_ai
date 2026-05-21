# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.LLM.Adapters.OpenAI do
  @moduledoc """
  OpenAI-compatible wire protocol: POST `/chat/completions`, SSE
  streaming of `data: <json>` lines, top-level `choices[0].message`
  in non-streaming responses, fragmented tool_call deltas in
  streamed responses (each chunk carries a partial
  `function.arguments` string the parser concatenates by index).

  Used by OpenAI/Anthropic/Google pools, and by Ollama pools that
  point at the `/v1` OpenAI-shim endpoint.
  """

  @behaviour DmhAi.LLM.Adapter

  alias DmhAi.Agent.LLM
  require Logger

  @impl true
  def chat_endpoint_url(%{base_url: base}),
    do: String.trim_trailing(base, "/") <> "/chat/completions"

  @impl true
  def build_body(model, messages, tools, stream, options) do
    base = %{model: model, messages: messages, stream: stream}

    # OpenAI-compatible servers (including ollama-cloud) only emit a
    # final usage chunk in streaming mode when the client opts in via
    # `stream_options.include_usage=true`. Without it the runtime's
    # `on_tokens` callback never fires for streaming calls and the
    # session_token_stats / worker_token_stats counters stay at 0.
    # Non-streaming calls always include `usage` in the response body
    # so this option is only relevant for stream=true.
    base =
      if stream do
        Map.put(base, :stream_options, %{include_usage: true})
      else
        base
      end

    base =
      if tools != [] do
        wrapped = Enum.map(tools, fn t -> %{type: "function", function: t} end)
        Map.put(base, :tools, wrapped)
      else
        base
      end

    if map_size(options) > 0, do: Map.put(base, :options, options), else: base
  end

  @impl true
  # Wire-format normalisation. The OpenAI chat-completions API requires
  # `messages[].tool_calls[].function.arguments` to be a JSON-encoded
  # **string**. Internally the runtime stores arguments as a decoded
  # **map** (so Police / tools can read structured fields without
  # re-parsing). Re-encode any map arguments back to strings before
  # sending. Idempotent: pre-stringified arguments pass through.
  def normalize_messages(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"]

      cond do
        role == "assistant" and is_list(calls) and calls != [] ->
          new_calls = Enum.map(calls, &stringify_arguments/1)

          msg
          |> Map.put(:tool_calls, new_calls)
          |> Map.delete("tool_calls")

        true ->
          msg
      end
    end)
  end

  @impl true
  def extract_message(body) do
    msg =
      case body["choices"] do
        [%{"message" => m} | _] when is_map(m) -> m
        _ -> %{}
      end

    usage = body["usage"] || %{}
    {usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0, msg}
  end

  @impl true
  def handle_stream_line(line, ctx) do
    payload = strip_data_prefix(line)

    cond do
      payload == "[DONE]" -> {:cont, false}
      payload == "" -> {:cont, false}
      true -> dispatch_payload(payload, ctx)
    end
  end

  @impl true
  def finalize_stream(ctx) do
    # Drain the accumulator (built by `accumulate_tool_calls/2`) into
    # the same list shape Ollama-native streaming produces, so the
    # downstream `normalize_tool_calls/1` works for both formats.
    # No accumulator state (or an unrecognised stale shape from a
    # previous reset) means nothing to drain — calls_key already
    # holds the default empty list from stream setup.
    case Process.get(ctx.tc_acc_key) do
      %{order: order, by_key: by_key} when order != [] ->
        calls = Enum.map(order, fn key -> Map.fetch!(by_key, key) end)
        Process.put(ctx.calls_key, calls)

      _ ->
        :ok
    end

    :ok
  end

  # ─── Internal ──────────────────────────────────────────────────────

  defp dispatch_payload(payload, ctx) do
    case Jason.decode(payload) do
      {:ok, %{"choices" => [choice | _]}} ->
        handle_choice(choice, ctx)
        {:cont, false}

      {:ok, %{"error" => %{"message" => msg}}} ->
        Logger.error("[LLM] model error: #{msg}")
        Process.put(ctx.err_key, msg)
        {:halt, true}

      {:ok, %{"error" => err}} when is_binary(err) ->
        Logger.error("[LLM] model error: #{err}")
        Process.put(ctx.err_key, err)
        {:halt, true}

      {:ok, decoded} ->
        # Some providers emit a final usage-only chunk after [DONE]
        # alternates; tally tokens if so.
        if usage = decoded["usage"] do
          tx = usage["prompt_tokens"] || 0
          rx = usage["completion_tokens"] || 0
          if ctx.on_tokens && (rx > 0 or tx > 0), do: ctx.on_tokens.(rx, tx)
        end

        {:cont, false}

      {:error, _} ->
        {:cont, false}
    end
  end

  defp handle_choice(%{"delta" => delta}, ctx) do
    # Content tokens (with embedded <think> tags handled identically to
    # other adapters — same split_think_token state machine).
    case delta["content"] do
      token when is_binary(token) and token != "" ->
        {think_tok, content_tok} =
          LLM.split_think_token(token, ctx.think_key, ctx.in_think_key)

        if think_tok != "" do
          send(ctx.reply_pid, {:thinking, think_tok})
        end

        if content_tok != "" do
          Process.put(ctx.text_key, Process.get(ctx.text_key) <> content_tok)
          send(ctx.reply_pid, {:chunk, content_tok})
        end

      _ ->
        :ok
    end

    # Some providers stream chain-of-thought alongside `delta.content`
    # in a separate field. Field name varies by provider:
    #   - DeepSeek/some OpenAI-compat servers: `reasoning_content`
    #   - ollama.com (gpt-oss, etc.): `reasoning`
    #   - some upstreams: `thinking`
    # Surface all of them as thinking tokens (routed to the runtime's
    # thinking_buffer + the FE's "Thinking out loud" <details> block).
    for key <- ["reasoning_content", "reasoning", "thinking"] do
      case delta[key] do
        token when is_binary(token) and token != "" ->
          send(ctx.reply_pid, {:thinking, token})

        _ ->
          :ok
      end
    end

    case delta["tool_calls"] do
      list when is_list(list) and list != [] ->
        accumulate_tool_calls(list, ctx)

      _ ->
        :ok
    end

    :ok
  end

  defp handle_choice(_, _ctx), do: :ok

  # OpenAI-compatible streaming gives every tool-call delta two fields
  # that look like identifiers but mean different things:
  #
  #   - `id`    — the server-assigned tool-call identity. Stable for life
  #               of one tool call.
  #   - `index` — its position in the final `tool_calls[]` array.
  #
  # Standard OpenAI streaming sends `id` ONCE (on the first chunk of a
  # tool call); subsequent fragments share the same `index` and grow
  # `function.arguments` by string concatenation. Some servers
  # (ollama.com) instead emit MULTIPLE complete tool calls in a single
  # delta, all with `index: 0` but distinct `id`s — in that wire
  # dialect, keying by `index` collapses them onto the same slot and
  # concatenates two valid JSON objects into a malformed one
  # (`{"slug":"a"}{"slug":"b"}`), which then fails to decode downstream.
  #
  # Identity is `id`. Use `id` as the slot key when present; fragments
  # without `id` continue the most recently opened slot (the OpenAI
  # streaming convention). The accumulator carries `order` for output
  # ordering and `last` for the continuation target.
  defp accumulate_tool_calls(deltas, ctx) do
    acc =
      case Process.get(ctx.tc_acc_key) do
        %{by_key: _, order: _, last: _} = a -> a
        _ -> %{by_key: %{}, order: [], last: nil}
      end

    new_acc = Enum.reduce(deltas, acc, &apply_delta/2)
    Process.put(ctx.tc_acc_key, new_acc)
  end

  defp apply_delta(delta, acc) do
    {key, acc} = resolve_slot_key(delta, acc)

    existing =
      Map.get(acc.by_key, key, %{
        "id" => "",
        "type" => "function",
        "function" => %{"name" => "", "arguments" => ""}
      })

    existing =
      case delta["id"] do
        id when is_binary(id) and id != "" -> Map.put(existing, "id", id)
        _ -> existing
      end

    existing =
      case delta["type"] do
        t when is_binary(t) and t != "" -> Map.put(existing, "type", t)
        _ -> existing
      end

    existing =
      case delta["function"] do
        %{} = fn_delta -> apply_function_delta(existing, fn_delta)
        _              -> existing
      end

    %{acc | by_key: Map.put(acc.by_key, key, existing), last: key}
  end

  defp resolve_slot_key(delta, acc) do
    case delta["id"] do
      id when is_binary(id) and id != "" ->
        order = if id in acc.order, do: acc.order, else: acc.order ++ [id]
        {id, %{acc | order: order}}

      _ ->
        # Continuation fragment — append to the most recently opened slot.
        # If no slot has been opened yet (the very first delta arrived
        # without an `id`), synthesise one from the `index`.
        key =
          case acc.last do
            nil -> "_idx_#{delta["index"] || 0}"
            k   -> k
          end

        order = if key in acc.order, do: acc.order, else: acc.order ++ [key]
        {key, %{acc | order: order}}
    end
  end

  defp apply_function_delta(existing, fn_delta) do
    fn_existing = existing["function"]

    fn_existing =
      case fn_delta["name"] do
        n when is_binary(n) and n != "" -> Map.put(fn_existing, "name", n)
        _ -> fn_existing
      end

    fn_existing =
      case fn_delta["arguments"] do
        args when is_binary(args) ->
          Map.put(fn_existing, "arguments",
                  (fn_existing["arguments"] || "") <> args)

        _ ->
          fn_existing
      end

    Map.put(existing, "function", fn_existing)
  end

  defp strip_data_prefix("data: " <> rest), do: String.trim(rest)
  defp strip_data_prefix("data:" <> rest), do: String.trim(rest)
  defp strip_data_prefix(other), do: String.trim(other)

  defp stringify_arguments(call) do
    fn_map = call["function"] || %{}
    args = fn_map["arguments"]

    new_args =
      cond do
        is_binary(args) -> args
        is_map(args)    -> Jason.encode!(args)
        is_nil(args)    -> "{}"
        true            -> Jason.encode!(args)
      end

    Map.put(call, "function", Map.put(fn_map, "arguments", new_args))
  end
end
