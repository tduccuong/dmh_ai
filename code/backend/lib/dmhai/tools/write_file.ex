# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.WriteFile do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Util.Path, as: SafePath

  @impl true
  def name, do: "write_file"

  @impl true
  def description,
    do:
      "Write content to a file in the session sandbox. Creates parent directories. " <>
      "Writes default to the job workspace. Use 'data/<file>' to write into the user's " <>
      "upload directory. Writes are rejected if they escape the session root."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path:    %{type: "string",
                     description: "Filename or relative path. Defaults to the job workspace."},
          content: %{type: "string", description: "Text content to write."}
        },
        required: ["path", "content"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}, ctx) when is_binary(path) do
    with {:ok, abs} <- SafePath.resolve(path, ctx) do
      File.mkdir_p!(Path.dirname(abs))

      case File.write(abs, content) do
        :ok ->
          {:ok, %{
            path:          abs,
            bytes_written: byte_size(content)
          }}

        {:error, reason} ->
          {:error, "Cannot write #{path}: #{reason}"}
      end
    end
  end

  def execute(_, _), do: {:error, "Missing required arguments: path and content"}
end
