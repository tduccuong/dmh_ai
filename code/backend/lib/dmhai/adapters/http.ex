defmodule Dmhai.Adapters.Http do
  @moduledoc """
  HTTP adapter — bridges the Plug request process with the UserAgent.

  Flow
  ----
  1. The Plug handler calls `dispatch/4` with the authenticated user, session_id,
     message content, and its own pid as the reply target.
  2. `dispatch/4` builds a Command and calls UserAgent.dispatch/2.
  3. The Plug handler then calls `receive_stream/1` which blocks in a receive
     loop, forwarding {:chunk, _} tokens to the caller as they arrive from the
     agent's inline task.
  4. When {:done, _} or {:error, _} arrives the loop returns.

  The Plug handler is responsible for writing the response (chunked HTTP /
  SSE / plain JSON) — this module only handles the piping.
  """

  @behaviour Dmhai.Agent.Adapter

  alias Dmhai.Agent.{Command, UserAgent}

  @default_timeout :timer.minutes(5)

  # ─── Dispatch ─────────────────────────────────────────────────────────────

  @doc """
  Build a Command from HTTP request data and dispatch it to the user's agent.
  Returns :ok immediately; the caller should follow up with receive_stream/1.
  """
  @spec dispatch(String.t(), String.t(), String.t(), pid(), keyword()) ::
          :ok | {:error, term()}
  def dispatch(user_id, session_id, content, reply_pid, opts \\ []) do
    command = %Command{
      type: :chat,
      content: content,
      session_id: session_id,
      reply_pid: reply_pid,
      images:      Keyword.get(opts, :images, []),
      image_names: Keyword.get(opts, :image_names, []),
      files:       Keyword.get(opts, :files, []),
      has_video:   Keyword.get(opts, :has_video, false),
      metadata:  Keyword.get(opts, :metadata, %{})
    }

    UserAgent.dispatch(user_id, command)
  end

  @doc """
  Blocking receive loop. Call this in the Plug handler process after dispatch/4.
  Returns a stream of events as `{:chunk, text}`, `{:done, result}`, or
  `{:error, reason}`.

  Pass a callback to consume events, e.g.:

      Http.receive_stream(fn
        {:chunk, text}   -> stream_to_conn(conn, text)
        {:done, _result} -> finalize_conn(conn)
        {:error, reason} -> send_error(conn, reason)
      end)
  """
  @spec receive_stream((term() -> any()), timeout()) :: :ok
  def receive_stream(callback, timeout \\ @default_timeout) do
    receive do
      {:status, text} ->
        callback.({:status, text})
        receive_stream(callback, timeout)

      {:chunk, text} ->
        callback.({:chunk, text})
        receive_stream(callback, timeout)

      {:thinking, token} ->
        callback.({:thinking, token})
        receive_stream(callback, timeout)

      {:done, result} ->
        callback.({:done, result})
        :ok

      {:error, reason} ->
        callback.({:error, reason})
        :ok
    after
      timeout ->
        callback.({:error, :timeout})
        :ok
    end
  end

  # ─── Adapter callbacks ─────────────────────────────────────────────────────

  @impl true
  def send_chunk(reply_pid, chunk) when is_pid(reply_pid) do
    send(reply_pid, {:chunk, chunk})
    :ok
  end

  @impl true
  def send_done(reply_pid, result) when is_pid(reply_pid) do
    send(reply_pid, {:done, result})
    :ok
  end

  @impl true
  def send_error(reply_pid, reason) when is_pid(reply_pid) do
    send(reply_pid, {:error, reason})
    :ok
  end

  @impl true
  def notify(_user_id, _message) do
    # HTTP is a request/response protocol — no persistent push channel.
    # Notifications go through MsgGateway to other platforms (Telegram, etc.).
    :ok
  end
end
