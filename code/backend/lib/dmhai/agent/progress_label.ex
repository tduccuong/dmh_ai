# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.ProgressLabel do
  @moduledoc """
  Formats a session_progress label for a tool call.

  The raw LLM tool-call payload (`run_script({"script":"#!/bin/bash\\n..."})`)
  is ugly for the FE. This module returns a short, friendly one-liner:

      RunScript("#!/bin/bash Scan the local network for devices that might …")
      WebFetch("https://vnexpress.net/hai-a-hau-miss-world-vietnam-ve-que-…")
      CreateTask("Research quarterly revenue figures")

  Shape:
    - Tool name → PascalCase
    - Primary descriptive argument → sliced to `@preview_words` words and
      quoted
    - No-arg tools (datetime) → bare `DateTime()`
  """

  @preview_words 18

  # Per-tool: which argument is the "descriptive" one to show in the label.
  # If omitted, we fall back to the first string-valued arg or a bare label.
  @primary_arg %{
    "run_script"        => "script",
    "web_fetch"         => "url",
    "web_search"        => "query",
    "read_file"         => "path",
    "write_file"        => "path",
    "list_dir"          => "path",
    "extract_content"   => "path",
    "create_task"       => "task_title",
    "fetch_task"        => "task_id",
    "spawn_task"        => "task_id",
    "calculator"        => "expression",
    "save_credential"   => "target",
    "lookup_credential" => "target"
  }

  @doc """
  Build a friendly one-line label for the FE progress row.
  `name` is the tool name as called by the LLM (snake_case); `args` is
  the decoded arg map.
  """
  @spec format(String.t(), map()) :: String.t()
  def format(name, args) when is_binary(name) and is_map(args) do
    pretty = pascal_case(name)
    preview = preview_for(name, args)

    case preview do
      "" -> "#{pretty}()"
      p  -> "#{pretty}(\"#{p}\")"
    end
  end

  # ── private ───────────────────────────────────────────────────────────

  defp preview_for("update_task", args) do
    # Special case: update_task is usually a status flip, sometimes a rewrite.
    # Show "<task_id>: <status>" when status present, else the title/spec slice.
    tid = args["task_id"] || ""
    cond do
      is_binary(args["status"]) and args["status"] != "" ->
        "#{tid}: #{args["status"]}" |> truncate_words()
      is_binary(args["task_spec"]) and args["task_spec"] != "" ->
        "#{tid}: #{args["task_spec"]}" |> truncate_words()
      true ->
        tid
    end
  end

  defp preview_for(name, args) do
    key = Map.get(@primary_arg, name)

    val =
      cond do
        is_binary(key) and is_binary(args[key]) -> args[key]
        true -> first_string_value(args)
      end

    truncate_words(val || "")
  end

  # Collapse whitespace (so multi-line scripts don't blow up the preview),
  # trim to `@preview_words` whitespace-separated words, append ellipsis if
  # truncated. Escapes any embedded double-quotes so the label stays parseable.
  defp truncate_words(""), do: ""
  defp truncate_words(text) when is_binary(text) do
    words =
      text
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.split(" ", trim: true)

    slice = Enum.take(words, @preview_words)
    body = Enum.join(slice, " ")

    body = String.replace(body, "\"", "\\\"")

    if length(words) > @preview_words, do: body <> " …", else: body
  end

  defp first_string_value(args) when is_map(args) do
    Enum.find_value(args, fn
      {_k, v} when is_binary(v) and v != "" -> v
      _ -> nil
    end)
  end

  # snake_case → PascalCase (run_script → RunScript).
  defp pascal_case(name) do
    name
    |> String.split("_", trim: true)
    |> Enum.map_join("", &String.capitalize/1)
  end
end
