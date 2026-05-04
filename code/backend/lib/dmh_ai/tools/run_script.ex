# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.RunScript do
  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Agent.{AgentSettings, RunningTools, Sandbox}
  alias DmhAi.Permissions.SandboxUser

  @max_output 50_000

  # Prepended to every shell script before execution. Three guards:
  #
  #   1. `set -o pipefail` — pipeline exit = rightmost non-zero
  #      stage. Required so the model's `curl … | jq '.field'`
  #      surfaces curl's HTTP-error exit instead of silently
  #      collapsing to jq's 0 and stranding the runtime with
  #      `{:ok, "null"}`.
  #
  #   2. `curl()` wrapper — replaces the binary with a shell
  #      function that:
  #        a. invokes `command curl --fail-with-body --silent
  #           --show-error "$@"` so HTTP 4xx/5xx exits 22 with the
  #           error body still produced (not suppressed by `--fail`).
  #        b. captures curl's stdout into a tempfile, NOT into the
  #           outer pipeline. On exit 0, replays the tempfile to
  #           stdout (so downstream pipes see the body normally).
  #           On non-zero exit, replays the tempfile to STDERR with a
  #           `[curl exit N — response body below]` marker. This
  #           ensures the error envelope reaches the runtime log
  #           even when the model wrote `… | jq '.field'`, where
  #           jq would otherwise filter `{"error":...}` to `null`.
  #
  #      Why the tempfile (not `tee`): a `tee`-based design races
  #      against `pipefail` if a downstream stage closes early
  #      (`… | head -N`), turning curl's success into an exit-141
  #      SIGPIPE. The tempfile pattern moves capture out of the
  #      shell pipeline entirely — only curl's own exit code is
  #      observed.
  #
  #      Why the wrapper doesn't fight `-o file` flags: we redirect
  #      curl's stdout, not its `-o`. If the user passed `-o foo`
  #      curl writes the body to `foo` and produces nothing on
  #      stdout, so our tempfile is empty, our `cat` outputs
  #      nothing, and the user's file has the body — exactly what
  #      they asked for. Same for `-O`, `-OJ`, `-o-`, etc.
  #
  #   3. `wget()` wrapper — same pattern with
  #      `--content-on-error --tries=1`, which makes 4xx/5xx exit 8
  #      with the body still produced (and blocks wasteful retries
  #      on definitive failures).
  #
  # ### Opt-outs (model-visible, advertised in `description/0`):
  #
  #   - One-call bypass — invoke the binary directly:
  #         `command curl …`   `/usr/bin/curl …`
  #         `command wget …`   `/usr/bin/wget …`
  #     Skips both `--fail-with-body` and the tempfile capture.
  #     Use when you intentionally want curl to exit 0 on a 404
  #     (e.g. probing whether a resource exists).
  #
  #   - Whole-script bypass for `pipefail` only:
  #         `set +o pipefail` at the top of the model's script.
  #     Restores the default pipeline-exit semantics (rightmost
  #     command's exit code wins). The wrapper functions stay in
  #     effect — only the `pipefail` interaction is suspended.
  #
  # ### Caveats (documented for spec parity with isolation.md):
  #
  #   - **`pipefail` + early-close pipelines.** Patterns like
  #     `cmd | head -N`, `cmd | grep -m1`, `cmd | sed -n '1p; q'`
  #     will return SIGPIPE-141 instead of 0 when the LEFT side
  #     produces more data than the RIGHT side reads. This is
  #     inherent to `pipefail`, not specific to the wrappers.
  #     In production traces of agentic LLM scripts the pattern
  #     does not occur — models reach for semantic extraction
  #     (`jq`, `awk`, `grep` full-read) rather than positional
  #     truncation. If a script genuinely needs early-close
  #     truncation, prepend `set +o pipefail` to that script.
  #
  #   - **Body buffering on success.** `curl url | tar -xz` no
  #     longer streams — curl's body is fully buffered to a
  #     tempfile in `/tmp` before being cat'd into `tar`. Disk
  #     pressure for multi-GB downloads (sandbox `/tmp` isn't
  #     sized for bulk transfers); throughput is unchanged for
  #     the typical small-JSON case. Use `command curl …` for
  #     bulk streaming.
  #
  #   - **Mixed stdout from `--write-out` without `-o`.** A model
  #     writing `curl -w '%{http_code}' url` (no `-o`) gets the
  #     body PLUS the write-out template on stdout, in that
  #     order. Same as bare curl — no behavior change.
  #
  #   - **Language-level HTTP clients are not wrapped.** Python
  #     `requests`, Node `fetch`, etc. need their own status
  #     handling (`r.raise_for_status()` / equivalent). The
  #     wrapper is shell-only.
  #
  #   - **Non-shell shebangs are not affected.** The prelude is
  #     skipped for `#!/usr/bin/env python3`, `#!/usr/bin/env
  #     node`, `#!/usr/bin/env perl`, and any shebang whose
  #     interpreter is not `sh` / `bash` / `dash` / `ash` /
  #     `ksh` / `zsh`. See `shebang_kind/1`.
  @safety_prelude """
  set -o pipefail
  curl() {
    __dmh_body=$(mktemp 2>/dev/null || echo "/tmp/_dmh_curl_$$")
    command curl --fail-with-body --silent --show-error "$@" >"$__dmh_body"
    __dmh_rc=$?
    if [ "$__dmh_rc" -ne 0 ]; then
      echo "[curl exit $__dmh_rc — response body below]" >&2
      cat "$__dmh_body" >&2 2>/dev/null
      rm -f "$__dmh_body"
      return $__dmh_rc
    fi
    cat "$__dmh_body"
    rm -f "$__dmh_body"
    return 0
  }
  wget() {
    __dmh_body=$(mktemp 2>/dev/null || echo "/tmp/_dmh_wget_$$")
    command wget --content-on-error --tries=1 "$@" >"$__dmh_body"
    __dmh_rc=$?
    if [ "$__dmh_rc" -ne 0 ]; then
      echo "[wget exit $__dmh_rc — response body below]" >&2
      cat "$__dmh_body" >&2 2>/dev/null
      rm -f "$__dmh_body"
      return $__dmh_rc
    fi
    cat "$__dmh_body"
    rm -f "$__dmh_body"
    return 0
  }
  """

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

    HTTP-error visibility: shell scripts run with `set -o pipefail`. `curl` and `wget` are shell-function-wrapped so 4xx/5xx exits non-zero (curl: 22, wget: 8) with the response body replayed on STDERR. A failing pipeline surfaces to you as `exit N` — never extract a field with `jq` and assume `null` means "no records" without first seeing a successful response shape. Opt-outs: `command curl …` / `/usr/bin/curl …` bypass the wrapper for one call (use when a 4xx is the expected probe outcome); `set +o pipefail` at the top of your script restores default pipe semantics (use only if your script needs `cmd | head -N` style early-close pipelines, which would otherwise SIGPIPE-141 under `pipefail`). Language clients (Python `requests`, Node `fetch`, …) are NOT wrapped — call `r.raise_for_status()` or its equivalent before extracting fields.
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
    # Resolve the user's sandbox identity first. Provisioning is
    # idempotent — the cost on already-provisioned users is one
    # SQL read + one `docker exec id <name>` (~50 ms). On fresh
    # users it allocates UID, runs `useradd`, and sets host-dir
    # ownership.
    case provision(ctx) do
      {:ok, run_ctx} ->
        do_execute(command, ctx, run_ctx)

      {:error, reason} ->
        {:error, "sandbox provisioning failed: #{reason}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: script"}

  defp do_execute(command, ctx, run_ctx) do
    # Master-side workdir (used by tools that File.write directly).
    # Sandbox-side cwd (used by docker exec -w) is computed in run_ctx.
    workdir = resolve_workdir(ctx)
    File.mkdir_p!(workdir)

    session_id   = Map.get(ctx, :session_id, "")
    tool_call_id = Map.get(ctx, :tool_call_id, "")
    progress_row_id = Map.get(ctx, :progress_row_id)
    started_at_ms = System.system_time(:millisecond)
    poll_ms       = AgentSettings.tool_run_poll_interval_ms()
    max_runtime_ms = AgentSettings.run_script_max_runtime_ms()

    case launch(command, run_ctx) do
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
          poll_loop(pid, run_id, started_at_ms, poll_ms, max_runtime_ms, run_ctx)
        after
          if session_id != "", do: RunningTools.clear(session_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Resolve `{:ok, %{username, sandbox_cwd}}` for the given ctx.
  # Username drives `docker exec -u`; sandbox_cwd drives `docker exec -w`.
  # `username` is the per-user OS account for non-admin users, or
  # `dmh_ai-master-u` for admins. `sandbox_cwd` is the sandbox-side
  # path the script runs in — `/work/<email>/<session>/` for users,
  # `/work` for admin.
  defp provision(ctx) do
    user_id = Map.get(ctx, :user_id) || ""
    email   = Map.get(ctx, :user_email) || ""
    role    = Map.get(ctx, :user_role) || "user"
    session_id = Map.get(ctx, :session_id) || ""

    cond do
      role == "admin" ->
        {:ok,
         %{
           username:    SandboxUser.master_username(),
           sandbox_cwd: "/work"
         }}

      user_id == "" or email == "" ->
        # Defensive — should never happen in real chains. Surface a
        # clear error so the model retries rather than hanging.
        {:error, "missing user context (user_id or user_email empty)"}

      true ->
        case SandboxUser.ensure_provisioned(%{id: user_id, email: email}) do
          {:ok, uid} ->
            {:ok,
             %{
               username:    SandboxUser.username_for(uid),
               sandbox_cwd: sandbox_cwd_for(email, session_id)
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Sandbox-side path the script runs in. Falls back to `/work/<email>`
  # when there's no session (rare — e.g. ad-hoc tool invocations
  # outside a session loop). Master-side path is computed separately
  # via `Constants.session_workspace_dir/2`.
  defp sandbox_cwd_for(email, ""), do: Path.join("/work", to_string(email))

  defp sandbox_cwd_for(email, session_id) do
    safe_session = String.replace(to_string(session_id), ~r/[^\w\-]/, "_")
    Path.join(["/work", to_string(email), safe_session])
  end

  # ─── private ──────────────────────────────────────────────────────────────

  # Workdir preference: task workspace → session_root → /tmp fallback.
  defp resolve_workdir(ctx) do
    cond do
      is_binary(Map.get(ctx, :workspace_dir)) -> ctx.workspace_dir
      is_binary(Map.get(ctx, :session_root))  -> ctx.session_root
      true -> "/tmp/dmh_ai-run-" <> Integer.to_string(System.unique_integer([:positive]))
    end
  end

  # Spawn the script under nohup inside the sandbox container, capture
  # the PID, return immediately. Poll loop reads the log + exit code
  # files when the PID is no longer alive.
  #
  # `run_ctx` carries the per-user identity and sandbox-side cwd —
  # the docker exec runs as `dmh_ai-u<uid>` (or `dmh_ai-master-u`
  # for admins) with `-w` set to the user's session workspace
  # inside the container. Files written under cwd land on the
  # `user_workspaces` bind mount; everything outside is RO or
  # blocked by the per-user 0700 fence.
  defp launch(command, run_ctx) do
    b64 = Base.encode64(harden(command))
    run_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    # mkdir -p the sandbox cwd just in case (idempotent). The
    # workspace dir was created by SandboxUser.ensure_provisioned/1
    # at the email level; per-session subdir is created lazily here.
    launcher = """
    set -e
    mkdir -p /tmp/_dmh_runs
    mkdir -p '#{shell_escape(run_ctx.sandbox_cwd)}'
    printf '%s' '#{b64}' | base64 -d > /tmp/_dmh_runs/#{run_id}.sh
    chmod +x /tmp/_dmh_runs/#{run_id}.sh
    cd '#{shell_escape(run_ctx.sandbox_cwd)}' || cd /tmp
    nohup sh -c '/tmp/_dmh_runs/#{run_id}.sh; echo $? > /tmp/_dmh_runs/#{run_id}.exit' > /tmp/_dmh_runs/#{run_id}.log 2>&1 &
    echo $!
    """

    case docker_exec(launcher, @docker_exec_timeout_medium, run_ctx) do
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

  defp shell_escape(s), do: String.replace(to_string(s), "'", "'\\''")

  # Inject `@safety_prelude` so HTTP errors fail loudly. Three branches
  # by shebang shape: shell-shebang scripts get the prelude inserted
  # right after the shebang line (so the interpreter still picks the
  # right shell); shebang-less scripts get it prepended; non-shell
  # interpreters (python, node, perl, …) are left untouched — the
  # prelude is shell-only and would crash a Python parser.
  defp harden(script) when is_binary(script) do
    case shebang_kind(script) do
      :none ->
        @safety_prelude <> script

      :shell ->
        case String.split(script, "\n", parts: 2) do
          [shebang, rest] -> shebang <> "\n" <> @safety_prelude <> rest
          [only]          -> only <> "\n" <> @safety_prelude
        end

      :other ->
        script
    end
  end

  defp shebang_kind(script) do
    case String.split(script, "\n", parts: 2) do
      ["#!" <> rest | _] ->
        if Regex.match?(~r/\b(sh|bash|dash|ash|ksh|zsh)\b/, rest),
          do: :shell,
          else: :other

      _ ->
        :none
    end
  end

  # Wrap `System.cmd("docker", ["exec", ...])` in a Task with a hard
  # timeout. Without this, a stuck docker daemon would freeze the
  # caller indefinitely — every code path in this module funnels
  # through here so a single bad daemon can't wedge the chain.
  #
  # `run_ctx` (optional) selects the OS user for `docker exec -u`.
  # When omitted the exec runs as the container's default identity
  # (root). Some helpers (kill, drain, cleanup) operate on /tmp
  # files written by the user — they go through the same `-u` to
  # avoid permission errors.
  #
  # Returns:
  #   {:ok, output, exit_code}   on completion
  #   :timeout                    when the docker exec didn't return
  #                               within `timeout_ms`
  #   {:error, reason}            for raised exceptions
  defp docker_exec(shell_cmd, timeout_ms, run_ctx) do
    user_args =
      case run_ctx do
        %{username: name} when is_binary(name) and name != "" -> ["-u", name]
        _ -> []
      end

    args = ["exec"] ++ user_args ++ [Sandbox.container_name(), "sh", "-c", shell_cmd]

    task =
      Task.async(fn ->
        System.cmd("docker", args, stderr_to_stdout: true)
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
  defp poll_loop(pid, run_id, started_at_ms, poll_ms, max_runtime_ms, run_ctx) do
    Process.sleep(poll_ms)
    elapsed = System.system_time(:millisecond) - started_at_ms
    hard_ceiling = max_runtime_ms + @poll_loop_grace_ms

    cond do
      script_finished?(run_id, pid, run_ctx) ->
        finalize(pid, run_id, started_at_ms, run_ctx)

      elapsed > max_runtime_ms ->
        # Best-effort kill; if it survives we still return an error
        # rather than hang the chain.
        kill_pid(pid, "TERM", run_ctx)
        Process.sleep(1_000)
        if RunningTools.alive?(pid), do: kill_pid(pid, "KILL", run_ctx)
        partial = drain_log_only(run_id, run_ctx)
        cleanup_run_files(run_id, run_ctx)
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
        poll_loop(pid, run_id, started_at_ms, poll_ms, max_runtime_ms, run_ctx)
    end
  end

  # True when either the wrapper wrote `<run_id>.exit` (script
  # finished and recorded its exit code) OR the spawned PID isn't
  # alive AND no exit file (script crashed without recording).
  # Avoids hanging on PID 1's failure to reap zombies inside the
  # sandbox.
  defp script_finished?(run_id, pid, run_ctx) do
    if exit_file_exists?(run_id, run_ctx) do
      true
    else
      not RunningTools.alive?(pid)
    end
  end

  defp exit_file_exists?(run_id, run_ctx) do
    case docker_exec(
           "test -f /tmp/_dmh_runs/#{run_id}.exit && echo yes || echo no",
           @docker_exec_timeout_short,
           run_ctx
         ) do
      {:ok, output, _} -> String.trim(output) == "yes"
      _ -> false
    end
  end

  # Read log + exit code from the temp files, normalise into the same
  # `{:ok, output} | {:error, reason}` shape the previous synchronous
  # `run_script` returned, then unlink the temp files.
  defp finalize(_pid, run_id, _started_at_ms, run_ctx) do
    drain_cmd =
      "tail -c #{@max_output} /tmp/_dmh_runs/#{run_id}.log; printf '\\n@@DMH_EXIT@@\\n'; " <>
        "cat /tmp/_dmh_runs/#{run_id}.exit 2>/dev/null; " <>
        "rm -f /tmp/_dmh_runs/#{run_id}.sh /tmp/_dmh_runs/#{run_id}.log /tmp/_dmh_runs/#{run_id}.exit"

    case docker_exec(drain_cmd, @docker_exec_timeout_long, run_ctx) do
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

  defp kill_pid(pid, signal, run_ctx) when is_integer(pid) and signal in ["TERM", "KILL"] do
    _ = docker_exec("kill -#{signal} #{pid}", @docker_exec_timeout_short, run_ctx)

    :ok
  rescue
    _ -> :ok
  end

  defp drain_log_only(run_id, run_ctx) do
    case docker_exec(
           "tail -c #{@max_output} /tmp/_dmh_runs/#{run_id}.log 2>/dev/null",
           @docker_exec_timeout_long,
           run_ctx
         ) do
      {:ok, output, _} -> output
      _                -> ""
    end
  end

  defp cleanup_run_files(run_id, run_ctx) do
    _ = docker_exec(
      "rm -f /tmp/_dmh_runs/#{run_id}.sh /tmp/_dmh_runs/#{run_id}.log /tmp/_dmh_runs/#{run_id}.exit",
      @docker_exec_timeout_short,
      run_ctx
    )

    :ok
  rescue
    _ -> :ok
  end

  # First non-empty line of the script, trimmed. Used by FE for the
  # `run_script (Ns) → <preview>` decoration during execution. Keep
  # this short — FE truncates further with CSS ellipsis, so the BE
  # only needs to drop obviously useless leading whitespace.
  #
  # Redacted via `DmhAi.Util.Redact` before truncation so a
  # `TOKEN="ya29.…"` first line doesn't render the raw bearer in
  # the FE's running-tool indicator.
  defp script_preview(command) when is_binary(command) do
    command
    |> String.split("\n", trim: false)
    |> Enum.find_value("", fn line ->
      stripped = String.trim(line)
      if stripped != "", do: stripped, else: nil
    end)
    |> DmhAi.Util.Redact.call()
    |> String.slice(0, 200)
  end
end
