# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.RunScript do
  @behaviour Dmhai.Tools.Behaviour

  @default_timeout 30
  @max_timeout 120
  @max_output 50_000

  # Dedicated sandbox container for shell execution — separate from the DMH-AI
  # container so user commands don't run inside the app process.
  @sandbox_container "dmh_ai-assistant-sandbox"

  @impl true
  def name, do: "run_script"

  @impl true
  def description do
    """
    Write and run a script in ONE go to achieve your goal. Do NOT call this tool multiple times for sequential steps. Some examples:

    Bash script:
    ```
    #!/bin/bash
    curl -s https://foo.com | grep "pattern" > results.txt
    curl -s https://bar.com -XPOST -d @results.txt
    ```

    Python script:
    ```
    #!/usr/bin/env python3
    import urllib.request, json
    with urllib.request.urlopen("http://localhost:11434/api/tags") as r:
        data = json.load(r)
    for m in data["models"]:
        print(m["name"])
    ```

    ## The sandbox — **Alpine Linux**

    Your script runs inside an Alpine Linux container with **root** privileges. You can install anything you need. Output capped at 50 KB; default timeout 30 s (max 120 s).

    **Pre-installed:** `curl`, `wget`, `python3` (with `requests`, `httpx`), `jq`, `git`, `nodejs`, `npm`, standard BusyBox (`sh`, `awk`, `sed`, `grep`, `tar`, `gzip`, …).

    **Package manager: `apk`.** The sandbox uses Alpine's `apk` — NOT `apt-get`, NOT `yum`, NOT `dnf`. Those commands do not exist here; a script that calls them WILL fail with `command not found`. Install missing tools like this:

        apk add --no-cache <pkg1> <pkg2> …

    Common recipes inside the sandbox:

    - SSH with password to a remote host: `apk add --no-cache openssh-client sshpass`
    - Interactive SSH expect scripts: `apk add --no-cache expect`
    - Headless Chrome for scraping: `apk add --no-cache chromium`
    - Python extras beyond `requests`/`httpx`: `pip install <pkg>` (no virtualenv needed — you're root)

    ## Sandbox vs. remote target — KEEP THESE SEPARATE

    When your script opens an SSH session to a remote machine, **two distinct environments are in play**:

    1. **The sandbox (Alpine)** — where the commands BEFORE `ssh` / INSIDE `run_script` itself execute. Install prereqs here with `apk`.
    2. **The remote target** — where commands INSIDE the quoted `ssh "<cmd>"` block execute. Its distro determines ITS package manager (Ubuntu → `apt`, Fedora → `dnf`, Alpine → `apk`, …). Use the remote's package manager INSIDE the quoted block.

    Correct pattern:

        apk add --no-cache openssh-client sshpass          # sandbox-side prereq
        sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@host '
            sudo apt-get install -y docker.io              # remote-side — Ubuntu target
        '

    ## Recovery rule — when a script fails

    If a tool result contains `<cmd>: command not found` on a LOCAL (sandbox-side) command, your next action is to install `<cmd>` via `apk add --no-cache <pkg>` and retry. **Do NOT pivot to a completely different approach, and do NOT fall back to explaining the task to the user manually** — the user asked you to DO it, and you're root in the sandbox; install what you need. Only stop and explain if the failure is on the remote side (host unreachable, auth denied, etc.) and you genuinely can't proceed without more input.
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
            description: "The shell script to run as a single string. Write the full script inline — pipe commands, use conditionals, assign variables. Example: \"curl -s http://localhost:11434/api/tags | jq '.models | length'\""
          },
          timeout: %{
            type: "integer",
            description: "Timeout in seconds (default #{@default_timeout}, max #{@max_timeout})"
          }
        },
        required: ["script"]
      }
    }
  end

  @impl true
  def execute(%{"script" => command} = args, ctx) do
    timeout_s = min(Map.get(args, "timeout", @default_timeout), @max_timeout)
    workdir   = resolve_workdir(ctx)
    File.mkdir_p!(workdir)

    task =
      Task.async(fn ->
        # Write the script to a temp file via base64 so the kernel respects any
        # shebang (#!/usr/bin/env python3, #!/bin/bash, etc.) rather than always
        # forcing sh. Base64 is shelling-safe — its alphabet never contains quotes.
        b64 = Base.encode64(command)
        launcher = "printf '%s' '#{b64}' | base64 -d > /tmp/_dmh_run && chmod +x /tmp/_dmh_run && /tmp/_dmh_run"
        System.cmd(
          "docker",
          ["exec", "-w", workdir, @sandbox_container, "sh", "-c", launcher],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_s * 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        # Return raw stdout verbatim so the model sees what a human would see
        # running the command. workdir is already in session ctx; embedding it
        # would force JSON wrapping with newline escaping.
        _ = workdir
        {:ok, String.slice(output, 0, @max_output)}

      {:ok, {output, exit_code}} ->
        {:error, "exit #{exit_code}: #{String.slice(output, 0, @max_output)}"}

      nil ->
        {:error, "command timed out after #{timeout_s}s"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(_, _), do: {:error, "Missing required argument: script"}

  # ── private ─────────────────────────────────────────────────────────────

  # Preference order: task workspace → session_root → /tmp fallback.
  defp resolve_workdir(ctx) do
    cond do
      is_binary(Map.get(ctx, :workspace_dir)) -> ctx.workspace_dir
      is_binary(Map.get(ctx, :session_root))  -> ctx.session_root
      true -> "/tmp/dmhai-run-" <> Integer.to_string(System.unique_integer([:positive]))
    end
  end
end
