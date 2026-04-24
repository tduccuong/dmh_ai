# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Util.Path do
  @moduledoc """
  Path resolution + safety for worker-facing tools.

  Layout under each session_root:
      <session_root>/
        ├── data/                           ← user uploads
        ├── assistant/tasks/<task_id>/        ← assistant-origin scratch
        └── confidant/tasks/<task_id>/        ← confidant-origin scratch

  The tool root is `session_root` — tools may read any file anywhere below
  it. Escaping the session_root is rejected. Workspace = task's own scratch
  dir; used by default for relative writes and bash cwd. Deletion is only
  permitted within the workspace.

  ## Usage

      with {:ok, abs} <- Dmhai.Util.Path.resolve(path, ctx),
           :ok        <- Dmhai.Util.Path.within_session?(abs, ctx) do
        …
      end
  """

  @type ctx :: %{optional(atom) => any()}

  @doc """
  Resolve a user-supplied path to an absolute filesystem path, anchored to
  the ctx's session root.

  Rules:
    * Paths starting with "data/" or "/data/" → under session_data_dir.
    * Paths starting with "workspace/" or "/workspace/" → under workspace_dir.
    * Absolute paths → as-is (still validated against session_root).
    * Relative paths → anchored to workspace_dir if present, else session_root.

  Returns `{:ok, absolute_path}` or `{:error, reason}`.
  """
  @spec resolve(String.t(), ctx()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path, ctx) when is_binary(path) do
    session_root  = Map.get(ctx, :session_root)
    data_dir      = Map.get(ctx, :data_dir)
    workspace_dir = Map.get(ctx, :workspace_dir)

    abs =
      cond do
        is_nil(session_root) ->
          Path.expand(path)

        String.starts_with?(path, "data/") or String.starts_with?(path, "/data/") ->
          rel = path |> String.replace_prefix("/data/", "") |> String.replace_prefix("data/", "")
          Path.expand(Path.join(data_dir || session_root, rel))

        String.starts_with?(path, "workspace/") or String.starts_with?(path, "/workspace/") ->
          rel = path |> String.replace_prefix("/workspace/", "") |> String.replace_prefix("workspace/", "")
          Path.expand(Path.join(workspace_dir || session_root, rel))

        String.starts_with?(path, "/") ->
          Path.expand(path)

        true ->
          Path.expand(Path.join(workspace_dir || session_root, path))
      end

    if is_nil(session_root) or within?(abs, session_root) do
      {:ok, abs}
    else
      {:error, "Access denied: path escapes the session root (#{session_root})"}
    end
  end

  def resolve(_, _), do: {:error, "path must be a string"}

  @doc "Check whether an absolute path is inside the ctx's session root."
  @spec within_session?(String.t(), ctx()) :: boolean()
  def within_session?(abs_path, ctx) do
    case Map.get(ctx, :session_root) do
      nil  -> true          # no session context → no restriction
      root -> within?(abs_path, root)
    end
  end

  @doc "Check whether an absolute path is inside the task's workspace directory."
  @spec within_workspace?(String.t(), ctx()) :: boolean()
  def within_workspace?(abs_path, ctx) do
    case Map.get(ctx, :workspace_dir) do
      nil  -> false
      root -> within?(abs_path, root)
    end
  end

  @doc """
  Safe check that `abs` is a subpath of `root`. Both are normalised via
  `Path.expand/1` first so `../` traversal is defeated.
  """
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(abs, root) when is_binary(abs) and is_binary(root) do
    a = Path.expand(abs)
    r = Path.expand(root)
    a == r or String.starts_with?(a, r <> "/")
  end

  def within?(_, _), do: false
end
