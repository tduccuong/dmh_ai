# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.Bash do
  @behaviour Dmhai.Tools.Behaviour

  @default_timeout 30
  @max_timeout 120
  @max_output 50_000

  @impl true
  def name, do: "bash"

  @impl true
  def description,
    do:
      "Execute a shell command inside the job's workspace directory. " <>
      "Output is capped at 50 KB. Default timeout is 30s, max 120s. " <>
      "The current working directory is the job workspace — fetched files, " <>
      "temp output, etc. land there. Access user uploads via the 'data/' " <>
      "relative path (e.g. `cat ../../data/photo.jpg`)."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Shell command to execute"},
          timeout: %{
            type: "integer",
            description: "Timeout in seconds (default #{@default_timeout}, max #{@max_timeout})"
          }
        },
        required: ["command"]
      }
    }
  end

  @impl true
  def execute(%{"command" => command} = args, ctx) do
    timeout_s = min(Map.get(args, "timeout", @default_timeout), @max_timeout)
    workdir   = resolve_workdir(ctx)
    File.mkdir_p!(workdir)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], cd: workdir, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_s * 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, %{output: String.slice(output, 0, @max_output), workdir: workdir}}

      {:ok, {output, exit_code}} ->
        {:error, "exit #{exit_code}: #{String.slice(output, 0, @max_output)}"}

      nil ->
        {:error, "command timed out after #{timeout_s}s"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(_, _), do: {:error, "Missing required argument: command"}

  # ── private ─────────────────────────────────────────────────────────────

  # Preference order: job workspace → session_root → /tmp fallback.
  defp resolve_workdir(ctx) do
    cond do
      is_binary(Map.get(ctx, :workspace_dir)) -> ctx.workspace_dir
      is_binary(Map.get(ctx, :session_root))  -> ctx.session_root
      true -> "/tmp/dmhai-bash-" <> Integer.to_string(System.unique_integer([:positive]))
    end
  end
end
