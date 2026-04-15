# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.ListDir do
  @behaviour Dmhai.Tools.Behaviour

  @sandbox_root "/tmp/dmhai-sandbox"

  @impl true
  def name, do: "list_dir"

  @impl true
  def description, do: "List files and subdirectories in the user's sandbox. Useful after bash or write_file to see what was created."

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
            description: "Subdirectory to list, relative to sandbox root (default: sandbox root)"
          }
        },
        required: []
      }
    }
  end

  @impl true
  def execute(args, context) do
    user_id = get_in(context, [:user, :id]) || "anon"
    sandbox = Path.expand(Path.join(@sandbox_root, to_string(user_id)))
    File.mkdir_p!(sandbox)

    subpath = Map.get(args, "path", "")

    target =
      if subpath == "" do
        sandbox
      else
        Path.expand(Path.join(sandbox, subpath))
      end

    if String.starts_with?(target, sandbox) do
      case File.ls(target) do
        {:ok, entries} ->
          items =
            Enum.map(entries, fn name ->
              full = Path.join(target, name)

              case File.stat(full) do
                {:ok, stat} ->
                  %{
                    name: name,
                    type: if(stat.type == :directory, do: "dir", else: "file"),
                    size: stat.size
                  }

                _ ->
                  %{name: name, type: "unknown", size: 0}
              end
            end)

          {:ok, %{path: target, entries: items, count: length(items)}}

        {:error, :enoent} ->
          {:ok, %{path: target, entries: [], count: 0}}

        {:error, reason} ->
          {:error, "Cannot list #{target}: #{reason}"}
      end
    else
      {:error, "Access denied"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
