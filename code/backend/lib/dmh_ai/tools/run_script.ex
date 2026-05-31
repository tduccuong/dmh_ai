# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.RunScript do
  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Agent.{AgentSettings, RunningTools, Sandbox}
  alias DmhAi.Constants
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
  # Compose the safety prelude for a given user's keystore. The prelude
  # is prepended to every shell-shebang script before docker exec runs
  # it; it sets `set -o pipefail` and installs three shell-function
  # wrappers:
  #
  #   - `curl()` / `wget()` — make HTTP 4xx/5xx fail loudly with the
  #     response body on STDERR (otherwise a `curl | jq .field` quietly
  #     yields `null`).
  #   - `ssh()` — when the user has provisioned an identity for the
  #     `<user>@<host>` target via `provision_ssh_identity`, auto-inject
  #     `-i <path>` so the model can write plain `ssh ct@host …` and
  #     have it use the existing key without first calling the
  #     `provision_ssh_identity` tool to learn the path. Wrapper is a
  #     no-op when the user explicitly passes `-i`, or when no matching
  #     key file exists under the keystore.
  #
  # `keystore_dir` is the per-user `_keystore` mount path on the
  # sandbox side — same path as on master per Rule 17 unified mounts.
  defp safety_prelude(keystore_dir) when is_binary(keystore_dir) do
    """
    set -o pipefail
    __DMH_KEYSTORE='#{shell_escape(keystore_dir)}'
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
    ssh() {
      __dmh_has_i=0
      __dmh_target=
      for __dmh_arg in "$@"; do
        case "$__dmh_arg" in
          -i|-i=*) __dmh_has_i=1 ;;
          -*) : ;;
          *@*) [ -z "$__dmh_target" ] && __dmh_target="$__dmh_arg" ;;
        esac
      done
      if [ "$__dmh_has_i" = 0 ] && [ -n "$__dmh_target" ] && [ -n "$__DMH_KEYSTORE" ]; then
        __dmh_user="${__dmh_target%%@*}"
        __dmh_host="${__dmh_target#*@}"
        __dmh_user_san=$(printf '%s' "$__dmh_user" | sed 's/[^a-zA-Z0-9._-]/_/g')
        __dmh_host_san=$(printf '%s' "$__dmh_host" | sed 's/[^a-zA-Z0-9._-]/_/g')
        __dmh_key="$__DMH_KEYSTORE/.ssh/${__dmh_user_san}_${__dmh_host_san}"
        if [ -r "$__dmh_key" ]; then
          command ssh -i "$__dmh_key" "$@"
          return $?
        fi
      fi
      command ssh "$@"
    }
    """
  end

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
  def catalog_manifest, do: %{write_class: :write}

  @impl true
  def description do
    pre_installed = Sandbox.installed_tools() |> Enum.join(", ")

    """
    Run a shell script (bash / python / node / …).

    Sandbox: Alpine Linux (musl libc, BusyBox userland), Python 3, Node.js. Output cap 50 KB. Pre-installed: #{pre_installed}. Package manager is `apk` (NOT apt / yum / dnf). Non-admin scripts run under a LAN fence — outbound to RFC1918 / loopback / link-local (127.x, 10.x, 172.16-31.x, 192.168.x, 169.254.x) is REJECTed; public internet works, so `apk add` / `pip install` from public mirrors WILL succeed but cost a turn — prefer the preinstalled deliverable libs (`fpdf2`, `openpyxl`, `python-docx`, `Pillow`, `matplotlib`, `markdown`, `pyyaml`, `requests`, `httpx`) when one fits.

    Remote SSH: commands BEFORE `ssh` run in the Alpine sandbox (use `apk`); commands INSIDE `ssh "<cmd>"` run on the remote (use that distro's manager). Just write `ssh <user>@<host> "<cmd>"`; if the remote rejects auth (`Permission denied`), call `provision_ssh_identity` to either install a fresh key OR surface install-instructions to the user.

    HTTP-error visibility: shell scripts run with `set -o pipefail`. `curl` and `wget` are shell-function-wrapped so 4xx/5xx exits non-zero (curl: 22, wget: 8) with the response body replayed on STDERR. A failing pipeline surfaces to you as `exit N` — never extract a field with `jq` and assume `null` means "no records" without first seeing a successful response shape. Opt-outs: `command curl …` / `/usr/bin/curl …` bypass the wrapper for one call (use when a 4xx is the expected probe outcome); `set +o pipefail` at the top of your script restores default pipe semantics (use only if your script needs `cmd | head -N` style early-close pipelines, which would otherwise SIGPIPE-141 under `pipefail`). Language clients (Python `requests`, Node `fetch`, …) are NOT wrapped — call `r.raise_for_status()` or its equivalent before extracting fields.

    Sandbox capabilities: when the user asks for a format outside the preinstalled list (e.g. `.epub`, `.midi`, scientific formats, niche image codecs):
    1. Try the preinstalled set once for an adjacent shape (e.g. PDF instead of `.epub`, PNG chart instead of `.svg`-only library).
    2. If that doesn't fit, stop and tell the user truthfully: the sandbox doesn't have a library for the requested format, name what CAN be produced from the preinstalled set, and ask whether to proceed with an adjacent shape or have them process it on their end. Don't fabricate a hand-rolled file structure to pretend you succeeded — a malformed file the user "downloads" is worse than an honest "can't do that here".

    External APIs — order: use, ask, or search. If the user gave you the entry point (URL / endpoint / command), use it directly. If not, ask for the one concrete piece you need. Only if the user doesn't know either: `web_search` for *how to start*.

    Study before probe (HARD): when method names / parameter shapes / scope model are unknown, READ DOCS FIRST — `web_fetch` the canonical docs page. Don't curl the user's instance to discover the API by trial-and-error: each failed call burns a probe slot, and "method not found" / "parameter mismatch" tells you only that *your* call was wrong, not what's correct.

    Probe, then execute in ONE script: the first `run_script` may be a probe-batch (multiple curls in parallel). Once probes confirm what works, the NEXT `run_script` composes the full multi-step operation as a single script — bash variables chain values across steps:
    ```
    RESULT=$(curl ...); ID=$(echo "$RESULT" | jq ...); curl ... -d "${ID}"
    ```
    Aim for probe-then-execute as 2 turns total, not 5+. Each separate `run_script` is a full LLM round-trip.

    Compose end-to-end logic in one call as far as the objective extends; reduce intermediate data inside the script so the emit is the answer, around #{AgentSettings.tool_result_target_chars()} chars. Probe first only when you don't yet know the data shape.

    Five probe-batches max: after five against an unknown surface, either commit and execute using what you've confirmed works, OR stop and ask the user the specific question probes can't answer.

    Probe failure → research, not substitute: on `404` / `401` / `403` / "method not found" / "endpoint missing" / "ACCESS_DENIED" / auth errors: (1) `fetch_index` first; if it returns nothing useful, `web_fetch` the canonical docs (or `web_search` for the method name + API), (2) retry once with the corrected call shape or auth model, (3) then decide — working alternative → use it; feature genuinely unavailable in this auth context → surface the specific limitation to the user. Auth failures aren't a definitive "no" — they're often "wrong auth surface for this method" and need the same look-up-then-retry loop.

    "Alternative" = different API call, never different scope. Running the workflow once instead of creating a permanent trigger reframes the ask — don't substitute.

    Research inconclusive → ASK, don't improvise. Sparse results, ambiguous docs, an alternative that almost-works but isn't clearly confirmed → STOP and ask the user one specific question. Asking is not failure; substituting a smaller scope IS.

    Verify after mutate: after any state-changing call (create / update / delete), READ the resource back and inspect the field you intended to change. `{"result":true}` is acknowledgement, not proof.
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
  # `dmh_ai-master-u` for admins. `sandbox_cwd` is the per-session
  # path `/data/user_workspaces/<email>/<session>/` regardless of
  # role — admin shares the workspace tree like any user, only the
  # consuming uid (`dmh_ai-master-u` instead of `dmh_ai-u<uid>`)
  # differs.
  #
  # Public so the sandbox-runtime test tier (`test/sandbox/R01_*`)
  # can assert on the resolved cwd+username without booting the rest
  # of the launcher pipeline. Internal callers (`execute_async/2`)
  # stay the same.
  @doc false
  def provision(ctx) do
    user_id    = Map.get(ctx, :user_id) || ""
    email      = Map.get(ctx, :user_email) || ""
    role       = Map.get(ctx, :user_role) || "user"
    session_id = Map.get(ctx, :session_id) || ""

    cond do
      email == "" or session_id == "" ->
        # Hard fail rather than silently widen sandbox_cwd to the
        # workspaces ROOT — that would expose every other user's tree
        # to the running process.
        {:error, "missing user context (user_email or session_id empty)"}

      role == "admin" ->
        # Admins share the workspace tree like any user — only the
        # consuming OS account differs (`dmh_ai-master-u` is preset
        # in the sandbox image; non-admins get a per-uid account
        # allocated lazily). `uid_for/1` runs the same chown sweep
        # as the non-admin path so a session-subdir created earlier
        # by master-as-root gets repaired before the launcher cd's
        # into it.
        with {:ok, uid} <- SandboxUser.uid_for(%{role: "admin", email: email}) do
          {:ok,
           %{
             uid:           uid,
             username:      SandboxUser.master_username(),
             sandbox_cwd:   sandbox_cwd_for(email, session_id),
             keystore_dir:  ctx[:keystore_dir] || Constants.user_keystore_dir(email)
           }}
        end

      user_id == "" ->
        {:error, "missing user_id for non-admin context"}

      true ->
        with {:ok, uid} <- SandboxUser.ensure_provisioned(%{id: user_id, email: email}) do
          {:ok,
           %{
             uid:           uid,
             username:      SandboxUser.username_for(uid),
             sandbox_cwd:   sandbox_cwd_for(email, session_id),
             keystore_dir:  ctx[:keystore_dir] || Constants.user_keystore_dir(email)
           }}
        end
    end
  end

  # Per-uid scratch dir for the launcher's wrapper script + log +
  # exit-code file. Sharing a single `/tmp/_dmh_runs/` across uids
  # collapses with `Permission denied` once a second uid tries to
  # write there — the first caller gets ownership at default mode
  # 755. Per-uid paths sidestep the coordination problem entirely.
  defp run_dir(%{uid: uid}) when is_integer(uid), do: "/tmp/_dmh_runs_#{uid}"

  # Path the script runs in. `provision/1` short-circuits with an
  # error when session_id is empty, so this only ever sees the
  # populated case. Master and sandbox both mount the workspaces
  # tree at the SAME container path, so this single resolution works
  # in both views.
  defp sandbox_cwd_for(email, session_id) when is_binary(session_id) and session_id != "",
    do: Constants.session_workspace_dir(email, session_id)

  # ─── private ──────────────────────────────────────────────────────────────

  # Workdir preference: session workspace → session_root → /tmp fallback.
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
    b64 = Base.encode64(harden(command, run_ctx.keystore_dir))
    run_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    rd = run_dir(run_ctx)

    # mkdir -p the sandbox cwd just in case (idempotent). The
    # workspace dir was created by SandboxUser.ensure_provisioned/1
    # at the email level; per-session subdir is created lazily here.
    launcher = """
    set -e
    mkdir -p #{rd}
    mkdir -p '#{shell_escape(run_ctx.sandbox_cwd)}'
    printf '%s' '#{b64}' | base64 -d > #{rd}/#{run_id}.sh
    chmod +x #{rd}/#{run_id}.sh
    cd '#{shell_escape(run_ctx.sandbox_cwd)}' || cd /tmp
    nohup sh -c '#{rd}/#{run_id}.sh; echo $? > #{rd}/#{run_id}.exit' > #{rd}/#{run_id}.log 2>&1 &
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
  # by shebang shape:
  #
  #   - **No shebang** — kernel falls back to `/bin/sh` for `exec`,
  #     which on Debian (the post-#219 sandbox) is **dash**. dash does
  #     not support `set -o pipefail` and exits 2 immediately. We
  #     therefore force `#!/bin/bash` ourselves so the prelude
  #     actually executes.
  #
  #   - **Shell shebang** (`#!/bin/sh`, `#!/bin/bash`, `#!/bin/dash`,
  #     `#!/usr/bin/env bash`, …) — the user's shebang is REPLACED
  #     with `#!/bin/bash` for the same reason: a `#!/bin/sh` line
  #     routes to dash on Debian and breaks the prelude. bash
  #     accepts every POSIX-sh script the user might have written,
  #     so the substitution is functionally invisible to scripts
  #     that didn't rely on shell-specific quirks.
  #
  #   - **Non-shell interpreter** (`#!/usr/bin/env python3`, node,
  #     perl, …) — the script is shell-only and the prelude is
  #     skipped entirely. Python/Node parsers would crash on the
  #     shell function definitions.
  defp harden(script, keystore_dir) when is_binary(script) and is_binary(keystore_dir) do
    prelude = safety_prelude(keystore_dir)

    case shebang_kind(script) do
      :none ->
        "#!/bin/bash\n" <> prelude <> script

      :shell ->
        rest =
          case String.split(script, "\n", parts: 2) do
            [_shebang, r] -> r
            [_shebang]    -> ""
          end

        "#!/bin/bash\n" <> prelude <> rest

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
    rd = run_dir(run_ctx)
    case docker_exec(
           "test -f #{rd}/#{run_id}.exit && echo yes || echo no",
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
    rd = run_dir(run_ctx)
    drain_cmd =
      "tail -c #{@max_output} #{rd}/#{run_id}.log; printf '\\n@@DMH_EXIT@@\\n'; " <>
        "cat #{rd}/#{run_id}.exit 2>/dev/null; " <>
        "rm -f #{rd}/#{run_id}.sh #{rd}/#{run_id}.log #{rd}/#{run_id}.exit"

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
            {:error, classify_exit_error(exit_code, body)}
        end

      {:ok, output, _} ->
        {:error, "drain failed: #{String.slice(output, 0, 400)}"}

      :timeout ->
        {:error, "drain timed out after #{@docker_exec_timeout_long}ms — docker daemon may be stuck"}

      {:error, reason} ->
        {:error, "drain failed: #{inspect(reason)}"}
    end
  end

  # Map a non-zero exit + stderr body onto a model-facing error string.
  # Generic exits stay as-is; recognised network-class shapes (DNS
  # resolution failure today) get a class tag + a hint naming the
  # input that would unblock — for `dns_unresolved` that's a routable
  # address, not credentials. Adding new classes is one cond branch.
  defp classify_exit_error(exit_code, body) do
    cond do
      dns_unresolved?(body) ->
        host = extract_dns_host(body)
        "exit #{exit_code} — dns_unresolved: Hostname #{inspect(host)} doesn't resolve from the sandbox. " <>
          "The sandbox can't see LAN-only names (mDNS, host /etc/hosts). " <>
          "Unblock by getting a routable IP or FQDN from the user — credentials won't fix this. " <>
          "Raw: #{String.slice(body, 0, @max_output)}"

      true ->
        "exit #{exit_code}: #{String.slice(body, 0, @max_output)}"
    end
  end

  defp dns_unresolved?(body) when is_binary(body) do
    body =~ ~r/Could not resolve hostname/i or
      body =~ ~r/Name or service not known/i or
      body =~ ~r/nodename nor servname provided/i or
      body =~ ~r/Temporary failure in name resolution/i
  end

  defp dns_unresolved?(_), do: false

  defp extract_dns_host(body) when is_binary(body) do
    case Regex.run(~r/Could not resolve host(?:name)?[:\s]+([^\s:]+)/i, body) do
      [_, h] -> h
      _ ->
        case Regex.run(~r/([\w.-]+):.*Name or service not known/i, body) do
          [_, h] -> h
          _      -> "<host>"
        end
    end
  end

  defp extract_dns_host(_), do: "<host>"

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
    rd = run_dir(run_ctx)
    case docker_exec(
           "tail -c #{@max_output} #{rd}/#{run_id}.log 2>/dev/null",
           @docker_exec_timeout_long,
           run_ctx
         ) do
      {:ok, output, _} -> output
      _                -> ""
    end
  end

  defp cleanup_run_files(run_id, run_ctx) do
    rd = run_dir(run_ctx)
    _ = docker_exec(
      "rm -f #{rd}/#{run_id}.sh #{rd}/#{run_id}.log #{rd}/#{run_id}.exit",
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
