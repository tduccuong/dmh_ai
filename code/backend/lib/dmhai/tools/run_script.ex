# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.RunScript do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.{AgentSettings, RunningTools, Sandbox}

  @max_output 50_000

  # Absolute hang guard. Whatever max_runtime the operator set, we
  # will NEVER stay in the poll loop past `max_runtime + this`. The
  # extra grace lets the kill-and-drain dance complete even on a
  # slow / partially-stuck docker daemon. Past this, we bail
  # unconditionally with an error so the chain can't wedge.
  @poll_loop_grace_ms 60_000

  # Per-docker-exec timeouts. Each `System.cmd("docker", ...)` is
  # wrapped in a Task with these caps so a stuck docker daemon
  # surfaces as a clean error rather than freezing the chain.
  @docker_exec_timeout_short 3_000   # liveness probes / signal sends
  @docker_exec_timeout_medium 5_000  # launcher / cleanup
  @docker_exec_timeout_long 10_000   # drain (reads log file)

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

    case docker_exec(launcher, @docker_exec_timeout_medium) do
      {:ok, output, 0} ->
        pid_line =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> List.last()

        case Integer.parse(pid_line || "") do
          {pid, _} -> {:ok, %{pid: pid, run_id: run_id}}
          :error   -> {:error, "could not parse PID from launcher output: #{inspect(output)}"}
        end

      {:ok, output, code} ->
        {:error, "launcher failed (exit #{code}): #{String.slice(output, 0, 400)}"}

      :timeout ->
        {:error, "launcher timed out after #{@docker_exec_timeout_medium}ms — docker daemon may be stuck"}

      {:error, reason} ->
        {:error, "launcher failed: #{inspect(reason)}"}
    end
  end

  # Wrap `System.cmd("docker", ["exec", ...])` in a Task with a hard
  # timeout. Without this, a stuck docker daemon would freeze the
  # caller indefinitely — every code path in this module funnels
  # through here so a single bad daemon can't wedge the chain.
  #
  # Returns:
  #   {:ok, output, exit_code}   on completion
  #   :timeout                    when the docker exec didn't return
  #                               within `timeout_ms`
  #   {:error, reason}            for raised exceptions
  defp docker_exec(shell_cmd, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(
          "docker",
          ["exec", Sandbox.container_name(), "sh", "-c", shell_cmd],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, code}} -> {:ok, output, code}
      nil -> :timeout
      {:exit, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Tight poll loop. Primary done-signal is the exit file's presence
  # — the wrapper writes it ONLY after the user script exits, so its
  # appearance means we're finished regardless of PID state. We can't
  # rely on `kill -0 <pid>` alone because the sandbox's PID 1 is
  # `tail -f /dev/null`, which doesn't reap children: an orphaned
  # wrapper shell becomes a zombie and `kill -0` keeps returning 0
  # (success — "alive") for the zombie's PID forever, hanging the
  # chain. Secondary signal (PID dead AND no exit file) catches
  # crashes that didn't get to write the exit code.
  defp poll_loop(pid, run_id, started_at_ms, poll_ms, max_runtime_ms) do
    Process.sleep(poll_ms)
    elapsed = System.system_time(:millisecond) - started_at_ms
    hard_ceiling = max_runtime_ms + @poll_loop_grace_ms

    cond do
      script_finished?(run_id, pid) ->
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

      elapsed > hard_ceiling ->
        # Belt-and-suspenders: even if `script_finished?` keeps
        # returning false (docker daemon stuck, exit file lookup
        # failing, etc.) and the max_runtime kill failed to free us,
        # the hard ceiling guarantees the chain unwedges. Past this
        # we give up without further docker calls.
        {:error,
         "run_script poll loop exceeded the hard hang-guard ceiling " <>
           "(max_runtime + #{div(@poll_loop_grace_ms, 1000)}s grace) — chain unwedged forcibly"}

      true ->
        poll_loop(pid, run_id, started_at_ms, poll_ms, max_runtime_ms)
    end
  end

  # True when either the wrapper wrote `<run_id>.exit` (script
  # finished and recorded its exit code) OR the spawned PID isn't
  # alive AND no exit file (script crashed without recording).
  # Avoids hanging on PID 1's failure to reap zombies inside the
  # sandbox.
  defp script_finished?(run_id, pid) do
    if exit_file_exists?(run_id) do
      true
    else
      not RunningTools.alive?(pid)
    end
  end

  defp exit_file_exists?(run_id) do
    case docker_exec(
           "test -f /tmp/_dmh_runs/#{run_id}.exit && echo yes || echo no",
           @docker_exec_timeout_short
         ) do
      {:ok, output, _} -> String.trim(output) == "yes"
      _ -> false
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

    case docker_exec(drain_cmd, @docker_exec_timeout_long) do
      {:ok, output, 0} ->
        {body, exit_code} = parse_drained(output)

        cond do
          exit_code == 0 ->
            {:ok, body}

          exit_code == nil ->
            # No exit code file → wrapper was killed (SIGTERM/SIGKILL,
            # OOM, container restart) before it could record. The model
            # gets a clear error so it can decide retry vs surface.
            {:error,
             "run_script process died without recording an exit code " <>
               "(likely killed by SIGTERM/SIGKILL — OOM, container restart, or " <>
               "external signal). Partial output: " <>
               String.slice(body, 0, @max_output)}

          true ->
            {:error, "exit #{exit_code}: #{String.slice(body, 0, @max_output)}"}
        end

      {:ok, output, _} ->
        {:error, "drain failed: #{String.slice(output, 0, 400)}"}

      :timeout ->
        {:error, "drain timed out after #{@docker_exec_timeout_long}ms — docker daemon may be stuck"}

      {:error, reason} ->
        {:error, "drain failed: #{inspect(reason)}"}
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
    _ = docker_exec("kill -#{signal} #{pid}", @docker_exec_timeout_short)

    :ok
  rescue
    _ -> :ok
  end

  defp drain_log_only(run_id) do
    case docker_exec(
           "tail -c #{@max_output} /tmp/_dmh_runs/#{run_id}.log 2>/dev/null",
           @docker_exec_timeout_long
         ) do
      {:ok, output, _} -> output
      _                -> ""
    end
  end

  defp cleanup_run_files(run_id) do
    _ = docker_exec(
      "rm -f /tmp/_dmh_runs/#{run_id}.sh /tmp/_dmh_runs/#{run_id}.log /tmp/_dmh_runs/#{run_id}.exit",
      @docker_exec_timeout_short
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
