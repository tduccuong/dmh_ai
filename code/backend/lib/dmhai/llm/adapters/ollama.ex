# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.LLM.Adapters.Ollama do
  @moduledoc """
  Ollama-native wire protocol: POST `/api/chat`, NDJSON streaming
  (one JSON object per line, terminated by `done: true`), top-level
  `message` in non-streaming responses, complete tool_call objects
  per line (no fragmentation across chunks like OpenAI SSE), and
  full support for the `options` block (`num_ctx`, `num_predict`,
  `temperature`, …) which the OpenAI-compat `/v1` shim silently
  ignores.

  The motivation for this adapter is exactly that gap: Ollama's
  default `num_ctx` is 4096, well below our system prompt, so every
  request through `/v1` was getting silently truncated. `/api/chat`
  honours `options.num_ctx` correctly.

  ## URL handling

  Pools configured against `<host>/v1` (the OpenAI-shim base) are
  rewritten to `<host>/api/chat` — the trailing `/v1` is stripped
  before appending the native path. Operators don't have to touch
  pool config when switching to this adapter.

  ## Tool call shape

  Unlike OpenAI SSE, `/api/chat` delivers each `tool_calls` entry
  fully formed in a single line. `function.arguments` arrives as a
  decoded **map**, not a JSON string. `finalize_stream/1` is a
  no-op; the runtime's `normalize_tool_calls/1` accepts both shapes.
  """

  @behaviour Dmhai.LLM.Adapter

  alias Dmhai.Agent.LLM
  require Logger

  @impl true
  def chat_endpoint_url(%{base_url: base}) do
    base
    |> root_url()
    |> Kernel.<>("/api/chat")
  end

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
  # Ollama `/api/chat` expects `function.arguments` as a decoded
  # object (Go unmarshals into `map[string]any`). The runtime
  # already stores arguments as a map, so pass through unchanged.
  def normalize_messages(messages), do: messages

  @impl true
  def extract_message(body) do
    {body["prompt_eval_count"] || 0, body["eval_count"] || 0, body["message"] || %{}}
  end

  @impl true
  def handle_stream_line(line, ctx) do
    case Jason.decode(line) do
      {:ok, %{"message" => %{"content" => token}} = decoded}
      when is_binary(token) and token != "" ->
        {think_tok, content_tok} =
          LLM.split_think_token(token, ctx.think_key, ctx.in_think_key)

        if think_tok != "" do
          send(ctx.reply_pid, {:thinking, think_tok})
        end

        if content_tok != "" do
          Process.put(ctx.text_key, Process.get(ctx.text_key) <> content_tok)
          send(ctx.reply_pid, {:chunk, content_tok})
        end

        # A line may carry both content AND tool_calls; check both.
        maybe_capture_tool_calls(decoded, ctx)
        maybe_tally_done(decoded, ctx)
        {:cont, false}

      {:ok, %{"message" => %{"thinking" => token}} = decoded}
      when is_binary(token) and token != "" ->
        send(ctx.reply_pid, {:thinking, token})
        maybe_capture_tool_calls(decoded, ctx)
        maybe_tally_done(decoded, ctx)
        {:cont, false}

      {:ok, %{"message" => %{"tool_calls" => calls}} = decoded}
      when is_list(calls) and calls != [] ->
        Process.put(ctx.calls_key, calls)
        maybe_tally_done(decoded, ctx)
        {:cont, false}

      {:ok, %{"error" => err}} ->
        Logger.error("[LLM] model error: #{err}")
        Process.put(ctx.err_key, err)
        {:halt, true}

      {:ok, decoded} ->
        maybe_tally_done(decoded, ctx)
        {:cont, false}

      {:error, _} ->
        {:cont, false}
    end
  end

  @impl true
  # Ollama-native delivers complete tool_call objects per line; nothing
  # to consolidate after the stream ends. OpenAI's adapter does the
  # opposite (re-assembles fragmented arguments).
  def finalize_stream(_ctx), do: :ok

  # ─── Internal ──────────────────────────────────────────────────────

  defp root_url(base) do
    base
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
    |> String.trim_trailing("/")
  end

  defp maybe_capture_tool_calls(%{"message" => %{"tool_calls" => calls}}, ctx)
       when is_list(calls) and calls != [] do
    existing = Process.get(ctx.calls_key) || []
    Process.put(ctx.calls_key, existing ++ calls)
  end

  defp maybe_capture_tool_calls(_, _ctx), do: :ok

  defp maybe_tally_done(%{"done" => true} = decoded, ctx) do
    tx = decoded["prompt_eval_count"] || 0
    rx = decoded["eval_count"] || 0
    if ctx.on_tokens && (rx > 0 or tx > 0), do: ctx.on_tokens.(rx, tx)
    :ok
  end

  defp maybe_tally_done(_, _ctx), do: :ok
end
