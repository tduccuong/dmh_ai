# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.ThinkingBuffer do
  @moduledoc """
  Per-session buffer for the model's currently-streaming chain-of-
  thought (`thinking`) tokens. Parallel to `StreamBuffer` but written
  to a separate column (`sessions.thinking_buffer`) so the FE can
  render a live `Thinking…` `<details>` block alongside the answer
  text without confusing the two streams.

  Flow:
    - on turn start, caller constructs a %Buffer{}
    - on every `{:thinking, token}` chunk from `LLM.stream`, caller
      calls `append/2` then `maybe_flush/1` (throttled to @flush_ms
      with the same cadence as StreamBuffer)
    - on turn end, caller calls `flush/1` (force) and `clear/2`
      (NULL the column)

  Each pipeline (Assistant / Confidant) owns its own collector loop
  that calls these helpers — the buffer module itself is shared
  leaf utility, not orchestration.
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
      do_write(buf.session_id, buf.user_id, buf.accumulated, now)
      %{buf | last_flush_ms: now}
    else
      buf
    end
  end

  @spec flush(t()) :: t()
  def flush(%__MODULE__{} = buf) do
    now = System.os_time(:millisecond)
    do_write(buf.session_id, buf.user_id, buf.accumulated, now)
    %{buf | last_flush_ms: now}
  end

  @doc """
  Read the current `thinking_buffer` text from DB. Returns an empty
  string when the column is NULL. Callers use this before `clear/2`
  to capture the accumulated thinking and persist it onto the
  finalized assistant message.
  """
  @spec read(String.t(), String.t()) :: String.t()
  def read(session_id, user_id) do
    try do
      case query!(Repo,
             "SELECT thinking_buffer FROM sessions WHERE id=? AND user_id=?",
             [session_id, user_id]) do
        %{rows: [[text]]} when is_binary(text) -> text
        _ -> ""
      end
    rescue
      e ->
        Logger.error("[ThinkingBuffer] read failed: #{Exception.message(e)}")
        ""
    end
  end

  @spec clear(String.t(), String.t()) :: :ok
  def clear(session_id, user_id) do
    try do
      query!(Repo,
             "UPDATE sessions SET thinking_buffer=NULL, thinking_buffer_ts=NULL WHERE id=? AND user_id=?",
             [session_id, user_id])
      :ok
    rescue
      e ->
        Logger.error("[ThinkingBuffer] clear failed: #{Exception.message(e)}")
        :ok
    end
  end

  # ── private ───────────────────────────────────────────────────────────

  defp do_write(session_id, user_id, text, ts) do
    try do
      query!(Repo,
             "UPDATE sessions SET thinking_buffer=?, thinking_buffer_ts=? WHERE id=? AND user_id=?",
             [text, ts, session_id, user_id])
    rescue
      e -> Logger.error("[ThinkingBuffer] write failed: #{Exception.message(e)}")
    end
  end
end
