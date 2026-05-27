# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.StreamBuffer do
  @moduledoc """
  Per-session buffer for the currently-streaming final answer.

  Backed by `DmhAi.Agent.EphemeralCache` (ETS), NOT the `sessions`
  table. Per-token DB writes would monopolise SQLite's single-writer
  slot in WAL mode and starve every other writer; this module's
  flushes are nanosecond-scale ETS inserts instead. See
  `arch_wiki/dmh_ai/architecture.md` §Streaming state lives in ETS,
  not the DB.

  Flow:
    - On turn start, caller constructs a %Buffer{} with zero baseline.
    - On every LLM token chunk, caller appends to the in-process
      accumulator and calls `maybe_flush/1` (writes the accumulated
      text to the EphemeralCache iff the throttle window has elapsed).
    - On turn end, caller calls `flush/1` (force-flush) then
      `clear/2` (drop the cache entry).

  The cache value is overwritten atomically on each flush. The
  FE-polling `/sessions/:id/poll` endpoint reads via `read/2`.
  """

  alias DmhAi.Agent.EphemeralCache
  require Logger

  @flush_ms 250
  @kind :stream

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

  @doc "Fresh buffer for a session — call once at the start of a streaming phase."
  @spec new(String.t(), String.t()) :: t()
  def new(session_id, user_id) do
    %__MODULE__{
      session_id: session_id,
      user_id: user_id,
      last_flush_ms: 0,
      accumulated: ""
    }
  end

  @doc "Append a chunk to the in-memory accumulator."
  @spec append(t(), String.t()) :: t()
  def append(%__MODULE__{} = buf, chunk) when is_binary(chunk) do
    %{buf | accumulated: buf.accumulated <> chunk}
  end

  @doc """
  Flush the accumulator to the EphemeralCache if the throttle window
  has elapsed. Returns the (possibly updated) buffer.
  """
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

  @doc "Force-flush regardless of throttle. Used at end of stream."
  @spec flush(t()) :: t()
  def flush(%__MODULE__{} = buf) do
    now = System.os_time(:millisecond)
    do_write(buf.session_id, buf.accumulated, now)
    %{buf | last_flush_ms: now}
  end

  @doc """
  Read the current buffered text. Returns an empty string when no
  active stream is buffering. Used by the FE-polling endpoint and by
  the tool-calls branch of `session_chain_loop` (which captures
  pre-tool narration the model streamed before emitting tool_calls,
  so it can be persisted as a real assistant message instead of being
  dropped by `clear/2`).
  """
  @spec read(String.t(), String.t()) :: String.t()
  def read(session_id, _user_id) when is_binary(session_id) do
    case EphemeralCache.get(session_id, @kind) do
      {text, _ts} when is_binary(text) -> text
      _ -> ""
    end
  end

  @doc "Drop the cache entry. Called after the final message has been appended to session.messages."
  @spec clear(String.t(), String.t()) :: :ok
  def clear(session_id, _user_id) when is_binary(session_id) do
    EphemeralCache.delete(session_id, @kind)
  end

  # ── private ───────────────────────────────────────────────────────────

  defp do_write(session_id, text, ts) do
    # Sanitize before every flush so the FE never polls a partial
    # pseudo-tool-call annotation (e.g. `[used: web_fetch({...`).
    # Truncates at the first tag opener. The in-memory accumulator
    # keeps the raw text intact — Police still sees the full bad
    # output at stream-end to reject / nudge on.
    sanitized = DmhAi.Agent.TextSanitizer.truncate_at_bookkeeping(text)
    EphemeralCache.put(session_id, @kind, sanitized, ts)
  end
end
