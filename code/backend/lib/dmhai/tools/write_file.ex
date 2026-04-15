# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.WriteFile do
  @behaviour Dmhai.Tools.Behaviour

  @sandbox_root "/tmp/dmhai-sandbox"

  @impl true
  def name, do: "write_file"

  @impl true
  def description,
    do: "Write content to a file in the user's sandbox directory. Creates parent directories as needed."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Filename or relative path within the sandbox (e.g. \"report.txt\" or \"data/output.csv\")"
          },
          content: %{type: "string", description: "Text content to write"}
        },
        required: ["path", "content"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}, context) do
    user_id = get_in(context, [:user, :id]) || "anon"
    sandbox = Path.expand(Path.join(@sandbox_root, to_string(user_id)))
    File.mkdir_p!(sandbox)

    # Resolve relative to sandbox; strip any leading "/" to prevent traversal
    safe_relative = path |> String.replace(~r"^/+", "") |> Path.expand("/") |> String.replace_prefix("/", "")
    target = Path.expand(Path.join(sandbox, safe_relative))

    if String.starts_with?(target, sandbox) do
      File.mkdir_p!(Path.dirname(target))

      case File.write(target, content) do
        :ok ->
          {:ok,
           %{
             path: target,
             relative_path: Path.relative_to(target, sandbox),
             bytes_written: byte_size(content)
           }}

        {:error, reason} ->
          {:error, "Cannot write #{path}: #{reason}"}
      end
    else
      {:error, "Access denied: path traversal not allowed"}
    end
  end

  def execute(_, _), do: {:error, "Missing required arguments: path and content"}
end
