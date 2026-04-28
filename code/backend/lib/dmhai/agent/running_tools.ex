# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.RunningTools do
  @moduledoc """
  ETS-backed registry of in-flight tool executions. Currently only
  populated by `run_script` — the runtime wraps every invocation in
  nohup, registers the tracked PID here, and the `/poll` handler
  surfaces an entry to the FE so the matching tool-call bubble can
  render a live `(Ns)` elapsed-time decoration.

  Storage: ETS table `:dmhai_running_tools`, public, set-keyed by
  `session_id`. Single entry per session (tool calls within a chain
  execute sequentially via `Enum.flat_map_reduce/3` in
  `UserAgent.execute_tools/2`), so a `set` table is sufficient.

  See architecture.md §Long-running tool execution.
  """

  alias Dmhai.Agent.Sandbox

  @table :dmhai_running_tools

  @typedoc "Entry held in ETS while a tool is executing."
  @type entry :: %{
          tool_call_id: String.t(),
          progress_row_id: integer() | nil,
          started_at_ms: integer(),
          script_preview: String.t(),
          pid: integer(),
          run_id: String.t()
        }

  @doc """
  Boot the ETS table. Called from `Dmhai.Application.start/2`.
  Idempotent — re-init on supervisor restart is safe.
  """
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Register an in-flight tool execution for the given session."
  @spec register(String.t(), entry) :: :ok
  def register(session_id, %{} = entry) when is_binary(session_id) do
    ensure_table()
    :ets.insert(@table, {session_id, entry})
    :ok
  end

  @doc "Look up the in-flight tool execution for a session, if any."
  @spec lookup(String.t()) :: entry | nil
  def lookup(session_id) when is_binary(session_id) do
    case :ets.info(@table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@table, session_id) do
          [{^session_id, entry}] -> entry
          _ -> nil
        end
    end
  end

  @doc "Clear the in-flight entry (tool finished or was killed)."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table, session_id) && :ok
    end
  end

  @doc """
  Best-effort kill of any in-flight tool process for the session.
  Sends SIGTERM, sleeps 2 s, then SIGKILL if still alive. Always
  clears the ETS entry so a stuck `kill -0` lookup can never wedge
  the chain.

  Returns `{:killed, entry}` if an entry was found, `:none` otherwise.
  """
  @spec kill_all_for_session(String.t()) :: {:killed, entry} | :none
  def kill_all_for_session(session_id) when is_binary(session_id) do
    case lookup(session_id) do
      nil ->
        :none

      %{pid: pid} = entry ->
        send_signal(pid, "TERM")
        Process.sleep(2_000)
        if alive?(pid), do: send_signal(pid, "KILL")
        clear(session_id)
        {:killed, entry}
    end
  end

  @doc "True iff the given PID is alive inside the sandbox container."
  @spec alive?(integer()) :: boolean()
  def alive?(pid) when is_integer(pid) do
    case System.cmd(
           "docker",
           ["exec", Sandbox.container_name(), "sh", "-c", "kill -0 #{pid} 2>/dev/null; echo $?"],
           stderr_to_stdout: true
         ) do
      {output, _} -> String.trim(output) == "0"
    end
  rescue
    _ -> false
  end

  # ─── private ──────────────────────────────────────────────────────────────

  defp ensure_table do
    case :ets.info(@table) do
      :undefined -> init()
      _ -> :ok
    end
  end

  defp send_signal(pid, signal) when is_integer(pid) and signal in ["TERM", "KILL"] do
    System.cmd(
      "docker",
      ["exec", Sandbox.container_name(), "sh", "-c", "kill -#{signal} #{pid}"],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _ -> :ok
  end
end
