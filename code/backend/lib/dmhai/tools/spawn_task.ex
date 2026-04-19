# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.SpawnTask do
  @moduledoc """
  Worker tool: spawn a short-lived background process to run a bash command.

  The spawned process:
    - optionally waits `delay_ms` before running
    - executes the command
    - sends {:subtask_result, output} back to the worker's mailbox
    - reports progress to the parent UserAgent

  The worker loop drains {:subtask_result, ...} messages at the top of each
  iteration, so the result becomes visible to the LLM on the very next step.

  Use this instead of Process.sleep in periodic tasks — the worker stays
  responsive while the sub-task is running.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.AgentSettings
  require Logger

  @impl true
  def name, do: "spawn_task"

  @impl true
  def description,
    do:
      "Run a bash command asynchronously; result arrives in your next iteration. " <>
        "Use for deferred or periodic work instead of blocking in-loop."

  @impl true
  def execute(%{"command" => cmd} = args, ctx) do
    delay_ms = Map.get(args, "delay_ms", 0)
    worker_pid = Map.get(ctx, :worker_pid)
    worker_id = Map.get(ctx, :worker_id, "unknown")

    timeout_s = AgentSettings.spawn_task_timeout_secs()

    Task.start(fn ->
      try do
        if delay_ms > 0, do: Process.sleep(delay_ms)

        task = Task.Supervisor.async_nolink(Dmhai.Agent.TaskSupervisor, fn ->
          System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)
        end)

        output =
          case Task.yield(task, timeout_s * 1_000) || Task.shutdown(task, :brutal_kill) do
            {:ok, {out, 0}}    -> String.trim(out)
            {:ok, {out, code}} -> "exit #{code}: #{String.trim(out)}"
            {:exit, reason}    -> "Error: command failed: #{inspect(reason)}"
            nil                -> "Error: command timed out after #{timeout_s}s — killed"
          end

        if worker_pid, do: send(worker_pid, {:subtask_result, output})
      rescue
        e ->
          msg = "spawn_task error: #{Exception.message(e)}"
          Logger.error("[SpawnTask] #{msg} worker=#{worker_id}")
          if worker_pid, do: send(worker_pid, {:subtask_result, msg})
      end
    end)

    label = if delay_ms > 0, do: "in #{delay_ms} ms", else: "immediately"
    {:ok, "Sub-task spawned (runs #{label}). Result will arrive in the next step."}
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          command: %{
            type: "string",
            description: "Bash command to execute in the sub-task."
          },
          delay_ms: %{
            type: "integer",
            description: "Milliseconds to wait before running (default 0). Use for periodic scheduling."
          }
        },
        required: ["command"]
      }
    }
  end
end
