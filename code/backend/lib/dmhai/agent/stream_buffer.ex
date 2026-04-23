# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.StreamBuffer do
  @moduledoc """
  Per-session buffer for the currently-streaming final answer.

  The Assistant / Confidant session loop accumulates tokens in process
  memory as the LLM generates the final text, and calls `update/3` to
  flush the accumulator to the `sessions.stream_buffer` DB column so the
  FE polling can render progressive text. Writes are throttled to
  `@flush_ms` (default 250 ms) to keep SQLite write pressure low.

  Flow:
    - on turn start, caller constructs a %Buffer{} with now-ts baseline
    - on every LLM token chunk, caller updates the accumulated text via
      `append/2` and then `maybe_flush/2` (writes to DB iff the throttle
      window has elapsed)
    - on turn end, caller calls `finalize/2` which flushes unconditionally
      and then `clear/2` (sets the column back to NULL)

  The column is atomic per call — we overwrite the whole blob each
  flush. For answers up to the model's context limit this is fine;
  SQLite handles it in tens of microseconds.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @flush_ms 250

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
  Flush the accumulator to `sessions.stream_buffer` if the throttle window
  has elapsed. Returns the (possibly updated) buffer.
  """
  @spec maybe_flush(t()) :: t()
  def maybe_flush(%__MODULE__{} = buf) do
    now = System.os_time(:millisecond)

    if now - buf.last_flush_ms >= @flush_ms do
      do_write(buf.session_id, buf.user_id, buf.accumulated, now)
      %{buf | last_flush_ms: now}
    else
      buf
    end
  end

  @doc "Force-flush regardless of throttle. Used at end of stream."
  @spec flush(t()) :: t()
  def flush(%__MODULE__{} = buf) do
    now = System.os_time(:millisecond)
    do_write(buf.session_id, buf.user_id, buf.accumulated, now)
    %{buf | last_flush_ms: now}
  end

  @doc "Clear the stream_buffer column. Called after the final message has been appended to session.messages."
  @spec clear(String.t(), String.t()) :: :ok
  def clear(session_id, user_id) do
    try do
      query!(Repo,
             "UPDATE sessions SET stream_buffer=NULL, stream_buffer_ts=NULL WHERE id=? AND user_id=?",
             [session_id, user_id])
      :ok
    rescue
      e ->
        Logger.error("[StreamBuffer] clear failed: #{Exception.message(e)}")
        :ok
    end
  end

  # ── private ───────────────────────────────────────────────────────────

  defp do_write(session_id, user_id, text, ts) do
    # Sanitize before every flush so the FE never polls a partial
    # pseudo-tool-call annotation (e.g. `[used: update_task({...`).
    # Truncates at the first tag opener. The in-memory accumulator
    # keeps the raw text intact — Police still sees the full bad
    # output at stream-end to reject / nudge on.
    sanitized = Dmhai.Agent.TextSanitizer.truncate_at_bookkeeping(text)

    try do
      query!(Repo,
             "UPDATE sessions SET stream_buffer=?, stream_buffer_ts=? WHERE id=? AND user_id=?",
             [sanitized, ts, session_id, user_id])
    rescue
      e -> Logger.error("[StreamBuffer] write failed: #{Exception.message(e)}")
    end
  end
end
