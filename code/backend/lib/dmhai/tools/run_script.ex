# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.RunScript do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.{AgentSettings, RunningTools, Sandbox}

  @max_output 50_000

  @impl true
  def name, do: "run_script"

  @impl true
  def description do
    pre_installed = Sandbox.installed_tools() |> Enum.join(", ")

    """
    Run a shell script (bash / python / node / …).

    Sandbox: Alpine Linux, root. Output cap 50 KB. Pre-installed: #{pre_installed}, plus BusyBox basics. Package manager is `apk` (NOT apt / yum / dnf): install missing with `apk add --no-cache <pkg>`; Python extras via `pip install <pkg>`. On `<cmd>: command not found`, install via `apk` and retry — don't pivot.

    Remote SSH: commands BEFORE `ssh` run in the Alpine sandbox (use `apk`); commands INSIDE `ssh "<cmd>"` run on the remote (use that distro's manager).
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          script: %{
            type: "string",
            description: "The full shell script as a single string. Compose all steps inline — pipes, variables, conditionals."
          }
        },
        required: ["script"]
      }
    }
  end

  @impl true
  def execute(%{"script" => command} = _args, ctx) do
    workdir = resolve_workdir(ctx)
    File.mkdir_p!(workdir)

    session_id   = Map.get(ctx, :session_id, "")
    tool_call_id = Map.get(ctx, :tool_call_id, "")
    progress_row_id = Map.get(ctx, :progress_row_id)
    started_at_ms = System.system_time(:millisecond)
    poll_ms       = AgentSettings.tool_run_poll_interval_ms()
    max_runtime_ms = AgentSettings.run_script_max_runtime_ms()

    case launch(command, workdir) do
      {:ok, %{pid: pid, run_id: run_id}} ->
        if session_id != "" and tool_call_id != "" do
          RunningTools.register(session_id, %{
            tool_call_id:    tool_call_id,
            progress_row_id: progress_row_id,
            started_at_ms:   started_at_ms,
            script_preview:  script_preview(command),
            pid:             pid,
            run_id:          run_id
          })
        end

        try do
          poll_loop(pid, run_id, started_at_ms, poll_ms, max_runtime_ms)
        after
          if session_id != "", do: RunningTools.clear(session_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(_, _), do: {:error, "Missing required argument: script"}

  # ─── private ──────────────────────────────────────────────────────────────

  # Workdir preference: task workspace → session_root → /tmp fallback.
  defp resolve_workdir(ctx) do
    cond do
      is_binary(Map.get(ctx, :workspace_dir)) -> ctx.workspace_dir
      is_binary(Map.get(ctx, :session_root))  -> ctx.session_root
      true -> "/tmp/dmhai-run-" <> Integer.to_string(System.unique_integer([:positive]))
    end
  end

  # Spawn the script under nohup inside the sandbox container, capture
  # the PID, return immediately. Poll loop reads the log + exit code
  # files when the PID is no longer alive.
  defp launch(command, workdir) do
    b64 = Base.encode64(command)
    run_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    safe_workdir = String.replace(workdir, "'", "'\\''")

    launcher = """
    set -e
    mkdir -p /tmp/_dmh_runs
    printf '%s' '#{b64}' | base64 -d > /tmp/_dmh_runs/#{run_id}.sh
    chmod +x /tmp/_dmh_runs/#{run_id}.sh
    cd '#{safe_workdir}' || cd /
    nohup sh -c '/tmp/_dmh_runs/#{run_id}.sh; echo $? > /tmp/_dmh_runs/#{run_id}.exit' > /tmp/_dmh_runs/#{run_id}.log 2>&1 &
    echo $!
    """

    case System.cmd(
           "docker",
           ["exec", Sandbox.container_name(), "sh", "-c", launcher],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        pid_line =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> List.last()

        case Integer.parse(pid_line || "") do
          {pid, _} -> {:ok, %{pid: pid, run_id: run_id}}
          :error   -> {:error, "could not parse PID from launcher output: #{inspect(output)}"}
        end

      {output, code} ->
        {:error, "launcher failed (exit #{code}): #{String.slice(output, 0, 400)}"}
    end
  end

  # Tight poll loop. Sleep `poll_ms`, check `kill -0 pid`, drain on
  # death. Max-runtime cap: if elapsed > `max_runtime_ms`, kill and
  # return an error.
  defp poll_loop(pid, run_id, started_at_ms, poll_ms, max_runtime_ms) do
    Process.sleep(poll_ms)
    elapsed = System.system_time(:millisecond) - started_at_ms

    cond do
      not RunningTools.alive?(pid) ->
        finalize(pid, run_id, started_at_ms)

      elapsed > max_runtime_ms ->
        # Best-effort kill; if it survives we still return an error
        # rather than hang the chain.
        kill_pid(pid, "TERM")
        Process.sleep(1_000)
        if RunningTools.alive?(pid), do: kill_pid(pid, "KILL")
        partial = drain_log_only(run_id)
        cleanup_run_files(run_id)
        {:error,
         "run_script exceeded max runtime of #{div(max_runtime_ms, 1000)}s. Last output: " <>
           String.slice(partial, 0, 1_000)}

      true ->
        poll_loop(pid, run_id, started_at_ms, poll_ms, max_runtime_ms)
    end
  end

  # Read log + exit code from the temp files, normalise into the same
  # `{:ok, output} | {:error, reason}` shape the previous synchronous
  # `run_script` returned, then unlink the temp files.
  defp finalize(_pid, run_id, _started_at_ms) do
    drain_cmd =
      "tail -c #{@max_output} /tmp/_dmh_runs/#{run_id}.log; printf '\\n@@DMH_EXIT@@\\n'; " <>
        "cat /tmp/_dmh_runs/#{run_id}.exit 2>/dev/null; " <>
        "rm -f /tmp/_dmh_runs/#{run_id}.sh /tmp/_dmh_runs/#{run_id}.log /tmp/_dmh_runs/#{run_id}.exit"

    case System.cmd(
           "docker",
           ["exec", Sandbox.container_name(), "sh", "-c", drain_cmd],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {body, exit_code} = parse_drained(output)

        cond do
          exit_code == 0 -> {:ok, body}
          exit_code == nil -> {:error, "process exited but no exit code recorded: #{String.slice(body, 0, @max_output)}"}
          true -> {:error, "exit #{exit_code}: #{String.slice(body, 0, @max_output)}"}
        end

      {output, _} ->
        {:error, "drain failed: #{String.slice(output, 0, 400)}"}
    end
  end

  defp parse_drained(output) do
    case String.split(output, "@@DMH_EXIT@@", parts: 2) do
      [body, tail] ->
        body  = String.trim_trailing(body, "\n")
        exit_code =
          case tail |> String.trim() |> Integer.parse() do
            {n, _} -> n
            :error -> nil
          end

        {body, exit_code}

      [only] ->
        {only, nil}
    end
  end

  defp kill_pid(pid, signal) when is_integer(pid) and signal in ["TERM", "KILL"] do
    System.cmd(
      "docker",
      ["exec", Sandbox.container_name(), "sh", "-c", "kill -#{signal} #{pid}"],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _ -> :ok
  end

  defp drain_log_only(run_id) do
    case System.cmd(
           "docker",
           ["exec", Sandbox.container_name(), "sh", "-c",
            "tail -c #{@max_output} /tmp/_dmh_runs/#{run_id}.log 2>/dev/null"],
           stderr_to_stdout: true
         ) do
      {output, _} -> output
    end
  rescue
    _ -> ""
  end

  defp cleanup_run_files(run_id) do
    System.cmd(
      "docker",
      ["exec", Sandbox.container_name(), "sh", "-c",
       "rm -f /tmp/_dmh_runs/#{run_id}.sh /tmp/_dmh_runs/#{run_id}.log /tmp/_dmh_runs/#{run_id}.exit"],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _ -> :ok
  end

  # First non-empty line of the script, trimmed. Used by FE for the
  # `run_script (Ns) → <preview>` decoration during execution. Keep
  # this short — FE truncates further with CSS ellipsis, so the BE
  # only needs to drop obviously useless leading whitespace.
  defp script_preview(command) when is_binary(command) do
    command
    |> String.split("\n", trim: false)
    |> Enum.find_value("", fn line ->
      stripped = String.trim(line)
      if stripped != "", do: stripped, else: nil
    end)
    |> String.slice(0, 200)
  end
end
