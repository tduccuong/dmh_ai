defmodule Dmhai.Tools.Bash do
  @behaviour Dmhai.Tools.Behaviour

  @sandbox_root "/tmp/dmhai-sandbox"
  @default_timeout 30
  @max_timeout 120
  @max_output 50_000

  @impl true
  def name, do: "bash"

  @impl true
  def description,
    do:
      "Execute a shell command in an isolated sandbox directory per user. " <>
        "Output is capped at 50 KB. Default timeout is 30s, max 120s."

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
  def execute(%{"command" => command} = args, context) do
    timeout_s = min(Map.get(args, "timeout", @default_timeout), @max_timeout)
    user_id = get_in(context, [:user, :id]) || "anon"
    workdir = Path.join(@sandbox_root, to_string(user_id))
    File.mkdir_p!(workdir)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], cd: workdir, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_s * 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        {:ok,
         %{
           output: String.slice(output, 0, @max_output),
           exit_code: exit_code,
           workdir: workdir
         }}

      nil ->
        {:ok,
         %{
           output: "(command timed out after #{timeout_s}s)",
           exit_code: 124,
           timed_out: true,
           workdir: workdir
         }}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(_, _), do: {:error, "Missing required argument: command"}
end
