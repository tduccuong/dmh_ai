# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.LLM.Adapter do
  @moduledoc """
  Behaviour for wire-protocol LLM adapters.

  An adapter knows how to:
  - construct the chat-completion endpoint URL for a resolved pool,
  - build the per-call request body in the protocol's expected shape,
  - normalise outbound message history to the wire shape the
    protocol expects (e.g. `function.arguments` as JSON string for
    OpenAI `/v1`, as decoded object for Ollama `/api/chat`),
  - parse a non-streaming response body into `{tx, rx, message}`,
  - handle a single streaming line (NDJSON or SSE) by mutating the
    shared process-dict streaming context built by `Dmhai.Agent.LLM`,
  - finalize the streaming accumulator (e.g. consolidate fragmented
    tool_call deltas) once the stream ends.

  Dispatch is `provider`-driven — `Pools.resolve/1` returns the
  pool's `provider` field and `Dmhai.Agent.LLM.adapter_for/1` maps
  it to the right adapter module. Adding a new wire protocol is a
  new adapter module plus one clause in `adapter_for/1`; account
  rotation, retry-on-throttle, transport timing, and thinking-tag
  extraction stay central.
  """

  @typedoc "Process-dict-keyed streaming context built by Dmhai.Agent.LLM."
  @type stream_ctx :: %{
          required(:text_key) => term(),
          required(:calls_key) => term(),
          required(:err_key) => term(),
          required(:think_key) => term(),
          required(:in_think_key) => term(),
          required(:tc_acc_key) => term(),
          required(:reply_pid) => pid(),
          required(:on_tokens) =>
            (non_neg_integer(), non_neg_integer() -> any()) | nil
        }

  @callback chat_endpoint_url(resolved :: map()) :: String.t()

  @callback build_body(
              model :: String.t(),
              messages :: [map()],
              tools :: [map()],
              stream :: boolean(),
              options :: map()
            ) :: map()

  @callback normalize_messages(messages :: [map()]) :: [map()]

  @callback extract_message(body :: map()) ::
              {prompt_tokens :: non_neg_integer(),
               completion_tokens :: non_neg_integer(),
               message :: map()}

  @callback handle_stream_line(line :: String.t(), ctx :: stream_ctx()) ::
              {:cont | :halt, halt? :: boolean()}

  @callback finalize_stream(ctx :: stream_ctx()) :: :ok
end
