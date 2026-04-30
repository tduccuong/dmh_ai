# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Commands.Pipelines.Folder do
  @moduledoc """
  Folder `/wiki` pipeline. Recursively walks the path, applies
  skiplist (`.git`, `node_modules`, etc.) + extension whitelist + size
  cap, runs each file through the File pipeline. Always async — folder
  walks can be slow.

  Sync ack: "Learning folder in the background." Final ack lists how
  many files were indexed and how many were skipped/failed.

  See specs/commands.md §Folder.
  """

  alias Dmhai.Commands.Pipelines.File, as: FilePipe
  alias Dmhai.Agent.{Oracle, UserAgentMessages}
  alias Dmhai.Commands.WikiAck
  require Logger

  @skip_dirs MapSet.new([
    ".git", ".venv", "node_modules", "__pycache__", ".next",
    "dist", "build", ".cache", "target", ".idea", ".vscode",
    "coverage", ".pytest_cache", ".mypy_cache", "_build"
  ])

  @text_exts MapSet.new(~w(.txt .md .rst .html .htm .json .yaml .yml .csv .log .xml .ini .toml))
  @doc_exts  MapSet.new(~w(.pdf .docx .pptx .xlsx .odt .rtf))
  @image_exts MapSet.new(~w(.jpg .jpeg .png .webp .gif))
  @code_exts MapSet.new(~w(.py .ex .exs .ts .tsx .js .jsx .go .rs .java .c .h .cpp .hpp .rb .sh .sql))

  @max_file_bytes 50 * 1024 * 1024
  @max_files_per_run 500

  @doc "Heuristic — does the arg look like a folder that exists?"
  @spec folder?(String.t()) :: boolean()
  def folder?(path) when is_binary(path) do
    String.starts_with?(path, "/") and Elixir.File.dir?(path)
  end

  def folder?(_), do: false

  @spec run_async(String.t(), String.t(), String.t()) :: {:ok, String.t()}
  def run_async(root, session_id, user_id) do
    Task.Supervisor.start_child(Dmhai.Agent.TaskSupervisor, fn ->
      do_run(root, session_id, user_id)
    end)

    # Path arg is a weak language signal; Oracle defaults to English
    # for path-shaped commands, which is fine.
    {:ok, Oracle.localize(WikiAck.accepted_ack(root), root)}
  end

  # Public for tests — walks the tree and returns the eligible-files
  # list synchronously, no ingestion. Lets unit tests verify skiplist
  # + extension-whitelist behaviour without needing a background Task.
  @doc false
  def list_eligible_files(root), do: walk(root, []) |> Enum.take(@max_files_per_run)

  defp do_run(root, session_id, user_id) do
    files = list_eligible_files(root)

    {indexed, skipped, errors} =
      Enum.reduce(files, {0, 0, []}, fn file, {ok, sk, errs} ->
        cond do
          Elixir.File.stat!(file).size > @max_file_bytes ->
            {ok, sk + 1, errs}

          true ->
            case FilePipe.run(file, session_id, user_id) do
              {:ok, _msg} -> {ok + 1, sk, errs}
              {:error, r} -> {ok, sk, [{file, r} | errs]}
            end
        end
      end)

    err_count = length(errors)
    err_summary =
      if err_count > 0 do
        first_err = errors |> List.last() |> elem(1)
        " (#{err_count} failed; first: #{first_err})"
      else
        ""
      end

    final_text =
      Oracle.localize(
        WikiAck.final_ack(root) <> " (#{indexed} indexed, #{skipped} skipped#{err_summary})",
        root
      )

    UserAgentMessages.append(session_id, user_id, %{
      role: "assistant",
      content: final_text,
      kind: "command_ack"
    })
  rescue
    e ->
      Logger.error("[Commands.Folder] crash on #{root}: #{Exception.message(e)}")
      UserAgentMessages.append(session_id, user_id, %{
        role: "assistant",
        content: Oracle.localize("Folder walk failed: #{Exception.message(e)}", root),
        kind: "command_ack"
      })
  end

  # Recursive walk — flat list of eligible files. Skiplist + extension
  # whitelist applied; cycle-safe via realpath stack. The caller caps
  # the total at `@max_files_per_run`.
  defp walk(dir, stack) do
    case Elixir.File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          cond do
            # Hidden files / dirs (start with `.`)
            String.starts_with?(entry, ".") ->
              []

            # Explicit skip dirs
            Elixir.File.dir?(full) and MapSet.member?(@skip_dirs, entry) ->
              []

            Elixir.File.dir?(full) ->
              real = realpath_safe(full)
              if real in stack, do: [], else: walk(full, [real | stack])

            Elixir.File.regular?(full) ->
              ext = full |> Path.extname() |> String.downcase()
              if eligible_ext?(ext), do: [full], else: []

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp eligible_ext?(ext) do
    MapSet.member?(@text_exts, ext) or MapSet.member?(@doc_exts, ext) or
      MapSet.member?(@image_exts, ext) or MapSet.member?(@code_exts, ext)
  end

  defp realpath_safe(path) do
    case Elixir.File.lstat(path) do
      {:ok, _} -> Path.expand(path)
      _        -> path
    end
  end
end
