# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.MidjobNotify do
  @moduledoc """
  Worker tool: push a mid-job notification to the user.

  Writes the full message to MasterBuffer (frontend toast + master LLM context),
  then signals the parent UserAgent to trigger a master response and fire
  external platform notifications (Telegram, etc.).

  The tool itself never calls MsgGateway directly — that lives in UserAgent.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.MasterBuffer

  # Minimum milliseconds between midjob_notify calls per worker.
  # Enforced via the worker process dictionary to prevent burst notifications.
  @min_interval_ms 8_000

  @impl true
  def name, do: "midjob_notify"

  @impl true
  def description,
    do:
      "Push a mid-job update to the user. " <>
        "The message appears in the chat thread (via the master agent) and is sent to " <>
        "all configured notification platforms (Telegram, etc.). " <>
        "Use this in periodic tasks to deliver each report as it is ready."

  @impl true
  def execute(%{"message" => message} = args, ctx) do
    worker_id = Map.get(ctx, :worker_id)

    # Rate-limit: reject if called too soon after the previous notify for this worker.
    # Uses the worker process dictionary — safe because each worker is a single process.
    pdict_key = {:midjob_last_ms, worker_id}
    now = System.os_time(:millisecond)
    last = Process.get(pdict_key, 0)
    elapsed = now - last

    if elapsed < @min_interval_ms do
      wait = @min_interval_ms - elapsed
      {:ok, "Rate-limited: called too soon (#{elapsed} ms since last notify, minimum #{@min_interval_ms} ms). Wait #{wait} ms before calling again."}
    else
      Process.put(pdict_key, now)

      summary = Map.get(args, "summary", String.slice(message, 0, 200))
      session_id = Map.get(ctx, :session_id)
      user_id = Map.get(ctx, :user_id)
      agent_pid = Map.get(ctx, :agent_pid)

      # Write content only (no summary) — fetch_notifications filters by summary IS NOT NULL,
      # so the frontend won't reload yet. The notification fires after master has responded.
      MasterBuffer.append(session_id, user_id, message, nil, worker_id)

      if agent_pid do
        send(agent_pid, {:midjob_notify, session_id, user_id, worker_id, summary})
      end

      {:ok, "Notification queued. The master agent will deliver it to the user."}
    end
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          message: %{
            type: "string",
            description: "Full message content to deliver to the user in the chat thread."
          },
          summary: %{
            type: "string",
            description:
              "Short one-liner for the notification toast and external push (max 200 chars). " <>
                "Defaults to the first 200 chars of message."
          }
        },
        required: ["message"]
      }
    }
  end
end
