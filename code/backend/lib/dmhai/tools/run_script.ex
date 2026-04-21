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

    Sandbox: Alpine Linux. Tools: curl, wget, python3 (requests, httpx pre-installed), jq, git, nodejs, npm. Install extras with apk. Output capped at 50 KB; default timeout 30s (max 120s).
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
        {:ok, %{output: String.slice(output, 0, @max_output), workdir: workdir}}

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
