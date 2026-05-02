# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Permissions.Migration do
  @moduledoc """
  One-shot, idempotent filesystem migration to the per-user permission
  layout (specs/permissions.md). Sweeps any pre-redesign session
  workspace dir from its old location

      <assets_dir>/<email>/<session_id>/workspace/...

  to the new tree

      <workspaces_dir>/<email>/<session_id>/...

  Re-runnable on every boot. New installs hit nothing to migrate and
  return `:ok` silently. Re-running on an already-migrated install is a
  no-op.

  Data-loss policy: on file-name collision in the destination, the
  source entry is **left in place** and a warning is logged. Preserving
  data is a stronger invariant than completing the migration.
  """

  require Logger

  alias DmhAi.Constants

  @doc """
  Production entry — sweeps the canonical paths from `Constants`.
  Always returns `:ok`. Errors are logged and swallowed so a
  partially-broken FS can't block boot.

  Skips silently when the canonical assets dir doesn't exist on the
  host filesystem — typical in test environments where `/data/` isn't
  mounted. In production both directories are bind-mounted by the
  generated docker-compose, so they always exist by the time master
  hits this hook.
  """
  @spec run() :: :ok
  def run do
    assets = Constants.assets_dir()

    if File.dir?(assets) do
      run(assets, Constants.workspaces_dir())
    else
      :ok
    end
  end

  @doc """
  Test-friendly form — sweep `assets_dir`, depositing migrated
  contents into `workspaces_dir`. Both paths are absolute.
  """
  @spec run(String.t(), String.t()) :: :ok
  def run(assets_dir, workspaces_dir)
      when is_binary(assets_dir) and is_binary(workspaces_dir) do
    File.mkdir_p!(workspaces_dir)

    count = sweep_assets(assets_dir, workspaces_dir)

    if count > 0 do
      Logger.info("[Permissions.Migration] migrated #{count} session workspace(s)")
    end

    :ok
  rescue
    e ->
      Logger.error("[Permissions.Migration] failed: #{Exception.message(e)}")
      :ok
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp sweep_assets(assets_dir, workspaces_dir) do
    case File.ls(assets_dir) do
      {:ok, emails} ->
        emails
        |> Enum.reject(&String.starts_with?(&1, "_"))
        |> Enum.reduce(0, fn email, acc ->
          acc + sweep_user(email, assets_dir, workspaces_dir)
        end)

      _ ->
        0
    end
  end

  defp sweep_user(email, assets_dir, workspaces_dir) do
    user_dir = Path.join(assets_dir, email)

    case File.ls(user_dir) do
      {:ok, entries} ->
        entries
        # `_keystore` and any future leading-underscore sibling of
        # session dirs is per-user, not per-session — leave it alone.
        |> Enum.reject(&String.starts_with?(&1, "_"))
        |> Enum.reduce(0, fn session, acc ->
          acc + sweep_session(email, session, assets_dir, workspaces_dir)
        end)

      _ ->
        0
    end
  end

  defp sweep_session(email, session, assets_dir, workspaces_dir) do
    src = Path.join([assets_dir, email, session, "workspace"])

    if File.dir?(src) do
      dst = Path.join([workspaces_dir, email, session])
      File.mkdir_p!(dst)
      move_contents(src, dst)
      _ = File.rmdir(src)
      1
    else
      0
    end
  end

  # Move every entry from `src` into `dst`. Leave entries in place on
  # collision — never overwrite. Cross-tree on the same filesystem
  # `File.rename/2` is atomic; if the trees end up on different
  # filesystems (operator override), `rename` returns
  # `{:error, :exdev}` and we fall back to copy + delete.
  defp move_contents(src, dst) do
    case File.ls(src) do
      {:ok, entries} ->
        Enum.each(entries, fn name ->
          src_path = Path.join(src, name)
          dst_path = Path.join(dst, name)

          cond do
            File.exists?(dst_path) ->
              Logger.warning(
                "[Permissions.Migration] collision, leaving in place: #{src_path}")

            true ->
              case File.rename(src_path, dst_path) do
                :ok ->
                  :ok

                {:error, :exdev} ->
                  # Cross-device — rename can't traverse it. Copy + remove.
                  case File.cp_r(src_path, dst_path) do
                    {:ok, _} -> _ = File.rm_rf(src_path); :ok
                    {:error, reason, _} ->
                      Logger.warning(
                        "[Permissions.Migration] copy failed for #{src_path}: #{inspect(reason)}")
                  end

                {:error, reason} ->
                  Logger.warning(
                    "[Permissions.Migration] rename failed for #{src_path}: #{inspect(reason)}")
              end
          end
        end)

      _ ->
        :ok
    end
  end
end
