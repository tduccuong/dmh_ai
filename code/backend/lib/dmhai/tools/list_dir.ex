# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.ListDir do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Util.Path, as: SafePath

  @impl true
  def name, do: "list_dir"

  @impl true
  def description,
    do:
      "List files and subdirectories in the session sandbox. Default is the task workspace. " <>
      "Pass 'data' to list user uploads, or any relative/absolute path under the session root."

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
            description: "Directory to list. Defaults to the task workspace."
          }
        },
        required: []
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    subpath = Map.get(args, "path", "")

    resolved =
      if subpath == "" do
        {:ok, Map.get(ctx, :workspace_dir) || Map.get(ctx, :session_root) || Path.expand(".")}
      else
        SafePath.resolve(subpath, ctx)
      end

    with {:ok, abs} <- resolved do
      File.mkdir_p!(abs)

      case File.ls(abs) do
        {:ok, entries} ->
          items =
            Enum.map(entries, fn name ->
              full = Path.join(abs, name)
              case File.stat(full) do
                {:ok, stat} ->
                  %{name: name,
                    type: if(stat.type == :directory, do: "dir", else: "file"),
                    size: stat.size}
                _ ->
                  %{name: name, type: "unknown", size: 0}
              end
            end)

          {:ok, %{path: abs, entries: items, count: length(items)}}

        {:error, :enoent} ->
          {:ok, %{path: abs, entries: [], count: 0}}

        {:error, reason} ->
          {:error, "Cannot list #{abs}: #{reason}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
