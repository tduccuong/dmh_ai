# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.ThinkingBuffer do
  @moduledoc """
  Per-session buffer for the model's currently-streaming chain-of-
  thought (`thinking`) tokens.

  Backed by `DmhAi.Agent.EphemeralCache` (ETS), parallel to
  `StreamBuffer` but with `kind = :thinking` so the FE can render a
  live `Thinking…` `<details>` block alongside the answer text
  without confusing the two streams. Persistence rationale identical
  to StreamBuffer's — see that module's doc and
  `arch_wiki/dmh_ai/architecture.md` §Streaming state lives in ETS,
  not the DB.

  Flow mirrors StreamBuffer:
    - on turn start, caller constructs a %Buffer{}
    - on every `{:thinking, token}` chunk from `LLM.stream`, caller
      calls `append/2` then `maybe_flush/1` (throttled to @flush_ms)
    - on turn end, caller calls `flush/1` (force) and `clear/2`
      (drop the cache entry)

  Each pipeline (Assistant / Confidant) owns its own collector loop
  that calls these helpers — the buffer module itself is shared
  leaf utility, not orchestration.
  """

  alias DmhAi.Agent.EphemeralCache

  @flush_ms 250
  @kind :thinking

  defstruct [
    :session_id,
    :user_id,
    :last_flush_ms,
    accumulated: ""
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          user_id: String.t(),
          last_flush_ms: integer(),
          accumulated: String.t()
        }

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, user_id) do
    %__MODULE__{session_id: session_id, user_id: user_id, last_flush_ms: 0, accumulated: ""}
  end

  @spec append(t(), String.t()) :: t()
  def append(%__MODULE__{} = buf, chunk) when is_binary(chunk) do
    %{buf | accumulated: buf.accumulated <> chunk}
  end

  @spec maybe_flush(t()) :: t()
  def maybe_flush(%__MODULE__{} = buf) do
    now = System.os_time(:millisecond)

    if now - buf.last_flush_ms >= @flush_ms do
      do_write(buf.session_id, buf.accumulated, now)
      %{buf | last_flush_ms: now}
    else
      buf
    end
  end

  @spec flush(t()) :: t()
  def flush(%__MODULE__{} = buf) do
    now = System.os_time(:millisecond)
    do_write(buf.session_id, buf.accumulated, now)
    %{buf | last_flush_ms: now}
  end

  @doc """
  Read the current buffered thinking text. Returns an empty string
  when no active stream is buffering. Callers use this before
  `clear/2` to capture the accumulated thinking and persist it onto
  the finalised assistant message.
  """
  @spec read(String.t(), String.t()) :: String.t()
  def read(session_id, _user_id) when is_binary(session_id) do
    case EphemeralCache.get(session_id, @kind) do
      {text, _ts} when is_binary(text) -> text
      _ -> ""
    end
  end

  @spec clear(String.t(), String.t()) :: :ok
  def clear(session_id, _user_id) when is_binary(session_id) do
    EphemeralCache.delete(session_id, @kind)
  end

  # ── private ───────────────────────────────────────────────────────────

  defp do_write(session_id, text, ts) do
    EphemeralCache.put(session_id, @kind, text, ts)
  end
end
