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
    Run a shell script (bash / python / node / …).

    Sandbox: Alpine Linux, root. Output cap 50 KB; default timeout 30 s (max 120 s). Pre-installed: #{pre_installed}, plus BusyBox basics. Package manager is `apk` (NOT apt / yum / dnf): install missing with `apk add --no-cache <pkg>`; Python extras via `pip install <pkg>`. On `<cmd>: command not found`, install via `apk` and retry — don't pivot.

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
