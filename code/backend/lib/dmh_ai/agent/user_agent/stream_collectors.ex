# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent.StreamCollectors do
  @moduledoc """
  Lightweight per-turn collector processes that drain the LLM stream
  into the session's `StreamBuffer` (answer) and `ThinkingBuffer`
  (reasoning). Spawned once per LLM call by the chain loop / Confidant
  pipeline; stopped synchronously once the LLM returns so any final
  buffered chunks land before the next persistence step reads them.
  """

  alias DmhAi.Agent.{StreamBuffer, ThinkingBuffer}

  @doc "Spawn an Assistant-side stream collector for this session."
  def spawn_assistant_stream_collector(session_id, user_id) do
    spawn(fn ->
      stream_collector_loop(
        StreamBuffer.new(session_id, user_id),
        ThinkingBuffer.new(session_id, user_id)
      )
    end)
  end

  @doc "Spawn a Confidant-side stream collector for this session."
  def spawn_confidant_stream_collector(session_id, user_id) do
    spawn(fn ->
      stream_collector_loop(
        StreamBuffer.new(session_id, user_id),
        ThinkingBuffer.new(session_id, user_id)
      )
    end)
  end

  @doc """
  Synchronously stop a collector pid: send `:stop`, monitor for `:DOWN`
  with a 1s budget, then return `:ok`. Buffers flush on exit, so the
  caller's subsequent `read/clear` sees a complete answer.
  """
  def stop_stream_collector(collector) when is_pid(collector) do
    if Process.alive?(collector) do
      send(collector, :stop)
      ref = Process.monitor(collector)
      receive do
        {:DOWN, ^ref, :process, ^collector, _} -> :ok
      after 1_000 -> :ok end
    end
    :ok
  end
  def stop_stream_collector(_), do: :ok

  defp stream_collector_loop(answer_buf, thinking_buf) do
    receive do
      {:chunk, token} when is_binary(token) ->
        new_answer = answer_buf |> StreamBuffer.append(token) |> StreamBuffer.maybe_flush()
        stream_collector_loop(new_answer, thinking_buf)

      {:thinking, token} when is_binary(token) ->
        new_thinking = thinking_buf |> ThinkingBuffer.append(token) |> ThinkingBuffer.maybe_flush()
        stream_collector_loop(answer_buf, new_thinking)

      :flush_and_stop ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
        :ok

      :stop ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
        :ok

      _ ->
        stream_collector_loop(answer_buf, thinking_buf)
    after
      120_000 ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
    end
  end
end
