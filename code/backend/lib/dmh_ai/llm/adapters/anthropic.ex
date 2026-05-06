# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.LLM.Adapters.Anthropic do
  @moduledoc """
  Anthropic Messages wire protocol: POST `<base_url>/messages`, SSE
  streaming via the Anthropic event format (`event: …` lines paired
  with `data: <json>`), top-level `content` array of typed blocks
  (`{"type":"text","text":...}` / `{"type":"tool_use","id":...,"name":...,"input":...}`).

  Auth uses `x-api-key` and `anthropic-version: 2023-06-01` headers
  (Bearer is rejected by the Anthropic API). System prompts live at
  the top-level `system` field, not as a `messages[]` entry.

  Used by Anthropic-API-shape pools — including non-Anthropic services
  that expose an Anthropic-compatible endpoint (e.g. MiniMax at
  `https://api.minimax.io/anthropic`).

  ## Tool-use shape

  Each `content` block of `type: "tool_use"` carries:
    - `id`    — opaque call id (round-tripped as `tool_call_id` in
                follow-up `tool_result` blocks)
    - `name`  — function name
    - `input` — decoded object (JSON args; never a string)

  Tool results are encoded as `user` messages whose content is a list
  of `{"type": "tool_result", "tool_use_id": id, "content": text}`
  blocks.
  """

  @behaviour DmhAi.LLM.Adapter

  alias DmhAi.Agent.LLM
  require Logger

  @anthropic_version "2023-06-01"
  @default_max_tokens 4096

  @doc """
  Auth headers Anthropic requires. Public so `DmhAi.Agent.LLM` can
  override the Bearer default at request time. Returns the header
  list to merge into the outbound request.
  """
  @spec auth_headers(String.t()) :: [{String.t(), String.t()}]
  def auth_headers(api_key) when is_binary(api_key) and api_key != "" do
    [
      {"x-api-key",         api_key},
      {"anthropic-version", @anthropic_version}
    ]
  end

  def auth_headers(_), do: [{"anthropic-version", @anthropic_version}]

  @impl true
  def chat_endpoint_url(%{base_url: base}),
    do: String.trim_trailing(base, "/") <> "/messages"

  @impl true
  def build_body(model, messages, tools, stream, options) do
    {system, rest} = split_system(messages)
    encoded = Enum.map(rest, &encode_message/1)
    max_tokens = Map.get(options, :max_tokens) || Map.get(options, "max_tokens") || @default_max_tokens

    base = %{
      model:      model,
      messages:   encoded,
      max_tokens: max_tokens,
      stream:     stream
    }

    base = if system != "", do: Map.put(base, :system, system), else: base

    base =
      if tools != [] do
        Map.put(base, :tools, Enum.map(tools, &encode_tool/1))
      else
        base
      end

    case Map.get(options, :temperature) || Map.get(options, "temperature") do
      t when is_number(t) -> Map.put(base, :temperature, t)
      _ -> base
    end
  end

  @impl true
  # The runtime stores tool-call arguments as decoded maps. Anthropic
  # consumes them the same way (`input` is an object, never a string),
  # so message normalisation is a no-op for the outbound shape; the
  # heavy lifting happens in `encode_message/1` inside `build_body/5`.
  def normalize_messages(messages), do: messages

  @impl true
  def extract_message(body) do
    content = body["content"] || []
    {text_parts, tool_uses} = split_content_blocks(content)
    text = Enum.join(text_parts, "")
    msg = build_assistant_message(text, tool_uses)

    usage = body["usage"] || %{}
    {usage["input_tokens"] || 0, usage["output_tokens"] || 0, msg}
  end

  @impl true
  def handle_stream_line(line, ctx) do
    payload = strip_data_prefix(line)

    cond do
      payload == "" -> {:cont, false}
      String.starts_with?(line, "event:") -> {:cont, false}
      true -> dispatch_payload(payload, ctx)
    end
  end

  @impl true
  def finalize_stream(ctx) do
    # Streamed tool_use blocks accumulate the JSON-string `input` deltas
    # by content-block index. Decode each accumulator and emit the
    # consolidated tool_calls list in the same shape as the OpenAI
    # adapter (so downstream `normalize_tool_calls/1` is uniform).
    acc = Process.get(ctx.tc_acc_key) || %{}

    if map_size(acc) > 0 do
      sorted =
        acc
        |> Map.to_list()
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_idx, raw} ->
          input =
            case raw["input_json"] do
              s when is_binary(s) and s != "" ->
                case Jason.decode(s) do
                  {:ok, m} -> m
                  _ -> %{}
                end

              _ ->
                %{}
            end

          %{
            "id"   => raw["id"] || "",
            "type" => "function",
            "function" => %{
              "name"      => raw["name"] || "",
              "arguments" => input
            }
          }
        end)

      Process.put(ctx.calls_key, sorted)
    end

    :ok
  end

  # ─── Internal: build_body ──────────────────────────────────────────

  defp split_system(messages) do
    {sys_msgs, rest} =
      Enum.split_with(messages, fn m -> (m[:role] || m["role"]) == "system" end)

    text =
      sys_msgs
      |> Enum.map(fn m -> m[:content] || m["content"] || "" end)
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    {text, rest}
  end

  defp encode_message(msg) do
    role = msg[:role] || msg["role"]
    content = msg[:content] || msg["content"] || ""
    calls = msg[:tool_calls] || msg["tool_calls"] || []

    case role do
      "assistant" when is_list(calls) and calls != [] ->
        text_blocks =
          if is_binary(content) and content != "" do
            [%{type: "text", text: content}]
          else
            []
          end

        tool_blocks =
          Enum.map(calls, fn call ->
            fn_map = call["function"] || %{}

            input =
              case fn_map["arguments"] do
                m when is_map(m) -> m
                s when is_binary(s) ->
                  case Jason.decode(s) do
                    {:ok, m} -> m
                    _ -> %{}
                  end
                _ -> %{}
              end

            %{
              type:  "tool_use",
              id:    call["id"] || "",
              name:  fn_map["name"] || "",
              input: input
            }
          end)

        %{role: "assistant", content: text_blocks ++ tool_blocks}

      "tool" ->
        tool_call_id = msg[:tool_call_id] || msg["tool_call_id"] || ""

        %{
          role: "user",
          content: [
            %{
              type:        "tool_result",
              tool_use_id: tool_call_id,
              content:     to_string(content)
            }
          ]
        }

      "assistant" ->
        %{role: "assistant", content: to_string(content)}

      _ ->
        %{role: "user", content: to_string(content)}
    end
  end

  defp encode_tool(tool) do
    %{
      name:         tool[:name] || tool["name"],
      description:  tool[:description] || tool["description"] || "",
      input_schema: tool[:parameters] || tool["parameters"] || %{type: "object", properties: %{}}
    }
  end

  # ─── Internal: extract_message ─────────────────────────────────────

  defp split_content_blocks(blocks) when is_list(blocks) do
    Enum.reduce(blocks, {[], []}, fn block, {text_acc, tool_acc} ->
      case block do
        %{"type" => "text", "text" => t} when is_binary(t) ->
          {text_acc ++ [t], tool_acc}

        %{"type" => "tool_use"} = b ->
          {text_acc,
           tool_acc ++
             [%{
                "id"   => b["id"] || "",
                "type" => "function",
                "function" => %{
                  "name"      => b["name"] || "",
                  "arguments" => b["input"] || %{}
                }
              }]}

        _ ->
          {text_acc, tool_acc}
      end
    end)
  end

  defp split_content_blocks(_), do: {[], []}

  defp build_assistant_message(text, []) do
    %{"role" => "assistant", "content" => text}
  end

  defp build_assistant_message(text, tool_calls) do
    %{
      "role" => "assistant",
      "content" => text,
      "tool_calls" => tool_calls
    }
  end

  # ─── Internal: streaming ────────────────────────────────────────────

  defp dispatch_payload(payload, ctx) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "content_block_start", "index" => idx, "content_block" => block}} ->
        handle_block_start(idx, block, ctx)
        {:cont, false}

      {:ok, %{"type" => "content_block_delta", "index" => idx, "delta" => delta}} ->
        handle_block_delta(idx, delta, ctx)
        {:cont, false}

      {:ok, %{"type" => "content_block_stop"}} ->
        {:cont, false}

      {:ok, %{"type" => "message_delta", "usage" => usage}} ->
        if ctx.on_tokens do
          tx = usage["input_tokens"] || 0
          rx = usage["output_tokens"] || 0
          if rx > 0 or tx > 0, do: ctx.on_tokens.(rx, tx)
        end

        {:cont, false}

      {:ok, %{"type" => "message_start", "message" => %{"usage" => usage}}}
          when is_map(usage) ->
        if ctx.on_tokens do
          tx = usage["input_tokens"] || 0
          rx = usage["output_tokens"] || 0
          if rx > 0 or tx > 0, do: ctx.on_tokens.(rx, tx)
        end

        {:cont, false}

      {:ok, %{"type" => "error", "error" => %{"message" => msg}}} ->
        Logger.error("[LLM] anthropic error: #{msg}")
        Process.put(ctx.err_key, msg)
        {:halt, true}

      {:ok, %{"type" => "message_stop"}} ->
        {:cont, false}

      {:ok, _} ->
        {:cont, false}

      {:error, _} ->
        {:cont, false}
    end
  end

  defp handle_block_start(idx, %{"type" => "tool_use"} = block, ctx) do
    acc = Process.get(ctx.tc_acc_key) || %{}

    entry = %{
      "id"   => block["id"] || "",
      "name" => block["name"] || "",
      "input_json" => ""
    }

    Process.put(ctx.tc_acc_key, Map.put(acc, idx, entry))
  end

  defp handle_block_start(_idx, _block, _ctx), do: :ok

  defp handle_block_delta(_idx, %{"type" => "text_delta", "text" => token}, ctx)
       when is_binary(token) and token != "" do
    {think_tok, content_tok} =
      LLM.split_think_token(token, ctx.think_key, ctx.in_think_key)

    if think_tok != "" do
      send(ctx.reply_pid, {:thinking, think_tok})
    end

    if content_tok != "" do
      Process.put(ctx.text_key, Process.get(ctx.text_key) <> content_tok)
      send(ctx.reply_pid, {:chunk, content_tok})
    end
  end

  defp handle_block_delta(_idx, %{"type" => "thinking_delta", "thinking" => token}, ctx)
       when is_binary(token) and token != "" do
    send(ctx.reply_pid, {:thinking, token})
  end

  defp handle_block_delta(idx, %{"type" => "input_json_delta", "partial_json" => partial}, ctx)
       when is_binary(partial) do
    acc = Process.get(ctx.tc_acc_key) || %{}

    entry =
      Map.get(acc, idx, %{
        "id" => "",
        "name" => "",
        "input_json" => ""
      })

    updated = Map.put(entry, "input_json", entry["input_json"] <> partial)
    Process.put(ctx.tc_acc_key, Map.put(acc, idx, updated))
  end

  defp handle_block_delta(_idx, _delta, _ctx), do: :ok

  defp strip_data_prefix("data: " <> rest), do: String.trim(rest)
  defp strip_data_prefix("data:" <> rest), do: String.trim(rest)
  defp strip_data_prefix(other), do: String.trim(other)
end
