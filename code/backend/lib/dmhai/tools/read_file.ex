# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.ReadFile do
  @behaviour Dmhai.Tools.Behaviour

  @sandbox_root "/tmp/dmhai-sandbox"
  @assets_root "/data/user_assets"
  @max_bytes 100_000

  @impl true
  def name, do: "read_file"

  @impl true
  def description,
    do:
      "Read the contents of a file. Paths are resolved relative to the user's sandbox directory. " <>
        "Uploaded assets are also accessible. Content is capped at 100 KB."

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
              "File path to read. Relative paths resolve inside the user's sandbox. " <>
                "Absolute paths must be within sandbox or uploaded assets."
          }
        },
        required: ["path"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path}, context) do
    user_id = get_in(context, [:user, :id]) || "anon"
    sandbox = Path.expand(Path.join(@sandbox_root, to_string(user_id)))
    assets = Path.expand(Path.join(@assets_root, to_string(user_id)))

    resolved =
      if String.starts_with?(path, "/") do
        Path.expand(path)
      else
        Path.expand(Path.join(sandbox, path))
      end

    allowed = [sandbox, assets]

    if Enum.any?(allowed, &String.starts_with?(resolved, &1)) do
      case File.read(resolved) do
        {:ok, content} ->
          truncated = byte_size(content) > @max_bytes

          {:ok,
           %{
             path: resolved,
             content: String.slice(content, 0, @max_bytes),
             truncated: truncated,
             size: byte_size(content)
           }}

        {:error, :enoent} ->
          {:error, "File not found: #{path}"}

        {:error, reason} ->
          {:error, "Cannot read #{path}: #{reason}"}
      end
    else
      {:error, "Access denied: #{path} is outside allowed directories"}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: path"}
end
