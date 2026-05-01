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
    # OpenAI SSE delivers tool_calls FRAGMENTED across chunks (each
    # delta carries a partial `function.arguments` string we accumulate
    # by index). Consolidate the per-index map into the same list shape
    # Ollama-native streaming produces, so the downstream
    # `normalize_tool_calls/1` works for both formats.
    acc = Process.get(ctx.tc_acc_key) || %{}

    if map_size(acc) > 0 do
      sorted =
        acc
        |> Map.to_list()
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(&elem(&1, 1))

      Process.put(ctx.calls_key, sorted)
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

    # Some providers stream chain-of-thought as `reasoning_content` or
    # `thinking` alongside `delta.content`. Surface as thinking tokens.
    for key <- ["reasoning_content", "thinking"] do
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

  defp accumulate_tool_calls(deltas, ctx) do
    acc = Process.get(ctx.tc_acc_key) || %{}

    new_acc =
      Enum.reduce(deltas, acc, fn delta, a ->
        idx = delta["index"] || 0

        existing =
          Map.get(a, idx, %{
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
            %{} = fn_delta ->
              fn_existing = existing["function"]

              fn_existing =
                case fn_delta["name"] do
                  n when is_binary(n) and n != "" -> Map.put(fn_existing, "name", n)
                  _ -> fn_existing
                end

              fn_existing =
                case fn_delta["arguments"] do
                  args when is_binary(args) ->
                    Map.put(
                      fn_existing,
                      "arguments",
                      (fn_existing["arguments"] || "") <> args
                    )

                  _ ->
                    fn_existing
                end

              Map.put(existing, "function", fn_existing)

            _ ->
              existing
          end

        Map.put(a, idx, existing)
      end)

    Process.put(ctx.tc_acc_key, new_acc)
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
