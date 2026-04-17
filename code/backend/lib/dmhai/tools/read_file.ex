# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.ReadFile do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Util.Path, as: SafePath

  @max_bytes 100_000

  @impl true
  def name, do: "read_file"

  @impl true
  def description,
    do:
      "Read a file from the session sandbox. " <>
      "Paths resolve against the job workspace by default; use 'data/<file>' " <>
      "to reach user uploads. Absolute paths must stay under the session root. " <>
      "Content capped at 100 KB."

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
            description:
              "File path. Examples: 'report.txt' (workspace), 'data/photo.jpg' (user upload), " <>
              "'workspace/output.csv' (explicit workspace). Relative paths default to the job workspace."
          }
        },
        required: ["path"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path}, ctx) when is_binary(path) do
    with {:ok, abs} <- SafePath.resolve(path, ctx) do
      case File.read(abs) do
        {:ok, content} ->
          {:ok, %{
            path:      abs,
            content:   String.slice(content, 0, @max_bytes),
            truncated: byte_size(content) > @max_bytes,
            size:      byte_size(content)
          }}

        {:error, :enoent} -> {:error, "File not found: #{path}"}
        {:error, reason}  -> {:error, "Cannot read #{path}: #{reason}"}
      end
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: path"}
end
