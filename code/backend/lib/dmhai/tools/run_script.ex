# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.RunScript do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Sandbox

  @default_timeout 30
  @max_timeout 120
  @max_output 50_000

  @impl true
  def name, do: "run_script"

  @impl true
  def description do
    pre_installed = Sandbox.installed_tools() |> Enum.join(", ")

    """
    Write and run a shell script (bash / python / node / …) in ONE call. Do NOT split sequential steps across multiple `run_script` calls — compose them into a single script with pipes, variables, and conditionals.

    ## Sandbox — Alpine Linux, root, `apk`

    Runs inside an Alpine container with root privileges. Output capped at 50 KB; default timeout 30 s (max 120 s). Pre-installed top-level packages: #{pre_installed}. Plus BusyBox basics (`sh`, `awk`, `sed`, `grep`, `find`, `tar`, `gzip`, …).

    The package manager is `apk` — NOT `apt` / `yum` / `dnf`. Install anything missing with `apk add --no-cache <pkg>`; Python extras via `pip install <pkg>`.

    ## Plan dependencies before writing

    List every external command your script will invoke. For each, check whether it's in the pre-installed set above. Any command NOT pre-installed must be installed with `apk add --no-cache <pkg>` as an earlier line of the SAME script, before the line that uses it. The recovery rule below is a safety net, not a plan — relying on it always costs an extra turn.

    ## Sandbox vs. remote target

    When your script opens an SSH session to a remote host, two distinct environments are in play:

    1. **Sandbox (Alpine)** — commands BEFORE `ssh` and the `run_script` script body itself. Install prereqs here with `apk`.
    2. **Remote target** — commands INSIDE the quoted `ssh "<cmd>"` block. Use the REMOTE distro's package manager there (Ubuntu → `apt`, Fedora → `dnf`, …), not Alpine's.

    ## Recovery rule

    If the tool result contains `<cmd>: command not found` on a LOCAL (sandbox-side) command, your next action is `apk add --no-cache <pkg>` and retry. Do NOT pivot to a different approach or fall back to explaining the task manually — you're root, install what you need. Only stop for remote-side failures you genuinely can't unblock (host unreachable, auth denied).
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
          },
          timeout: %{
            type: "integer",
            description: "Timeout in seconds (default #{@default_timeout}, max #{@max_timeout})."
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
          ["exec", "-w", workdir, Sandbox.container_name(), "sh", "-c", launcher],
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
