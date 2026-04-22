# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.LogTrace do
  @moduledoc """
  Global verbatim LLM call trace logger.

  When the `logTrace` admin setting is true, every LLM call and response
  across the entire system is appended to:

      /data/system_logs/llm_trace.log

  Each entry is tagged with:
    [Origin: <origin>]  — top-level context: confidant, assistant, system, search
    [Path:   <path>]    — module.function of the call site
    [Role:   <role>]    — what this LLM call does: assistant, confidant, ImageDescriber,
                          VideoDescriber, Compactor, Summarizer, WebSearch, ProfileExtractor,
                          Namer, etc.
    [Model:  <model>]   — provider::pool::model string
    [Phase:  <phase>]   — turn / classify / compact / detect / describe / etc.

  Callers pass a `trace: %{origin:, path:, role:, phase:}` keyword to LLM.call/stream.
  The model field is filled in by the LLM module.

  Enabled/disabled via the `logTrace` admin setting (default: false).
  """

  @doc """
  Append one complete LLM call block to the global trace log.

  `meta`     — map with :origin, :path, :role, :phase (all optional, default "?")
  `model_str` — the full model string from the LLM call
  `messages` — message list sent to the model
  `tools`    — tool schemas sent (list of maps)
  `result`   — {:ok, text | {:tool_calls, calls}} | {:error, reason}
  """
  def write(meta, model_str, messages, tools, result) do
    try do
      path = log_path()
      File.mkdir_p!(Path.dirname(path))

      entry = format_entry(meta, model_str, messages, tools, result)
      File.write!(path, entry, [:append])
    rescue
      e -> require(Logger); Logger.warning("[LogTrace] write failed: #{Exception.message(e)}")
    end
    :ok
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp log_path do
    dir = Application.get_env(:dmhai, :system_log_dir, "/data/system_logs")
    Path.join(dir, "llm_trace.log")
  end

  defp format_entry(meta, model_str, messages, tools, result) do
    origin = meta[:origin] || "?"
    path   = meta[:path]   || "?"
    role   = meta[:role]   || "?"
    phase  = meta[:phase]  || "?"

    header =
      "=== #{iso_now()} " <>
      "[Origin: #{origin}] [Path: #{path}] [Role: #{role}] [Model: #{model_str}] [Phase: #{phase}] ===\n"

    msgs_block  = format_messages(messages)
    tools_block = format_tools(tools)
    resp_block  = format_result(result)

    header <>
      "\n[MESSAGES]\n#{msgs_block}\n" <>
      "\n[TOOLS]\n#{tools_block}\n" <>
      "\n[RESPONSE]\n#{resp_block}\n" <>
      "\n---\n\n"
  end

  defp format_messages(messages) do
    Enum.map_join(messages, "\n\n", fn msg ->
      role    = Map.get(msg, :role)       || Map.get(msg, "role")       || "?"
      content = Map.get(msg, :content)    || Map.get(msg, "content")    || ""
      calls   = Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") || []
      images  = Map.get(msg, :images)     || Map.get(msg, "images")     || []

      tag = "[#{String.upcase(to_string(role))}]"

      cond do
        is_list(calls) and calls != [] ->
          call_strs = Enum.map_join(calls, "\n", fn c ->
            name = get_in(c, ["function", "name"]) || "?"
            args = get_in(c, ["function", "arguments"]) || %{}
            "  #{name}(#{Jason.encode!(args)})"
          end)
          "#{tag} (tool_calls)\n#{call_strs}"

        is_list(images) and images != [] ->
          img_summary = "[#{length(images)} image(s) attached, base64 omitted]"
          "#{tag}\n#{sanitize_content(content)}\n#{img_summary}"

        true ->
          "#{tag}\n#{sanitize_content(content)}"
      end
    end)
  end

  # Redact inline base64 blobs that may appear in content strings.
  defp sanitize_content(content) when is_binary(content) do
    Regex.replace(~r/data:image\/[a-z]+;base64,[A-Za-z0-9+\/=]{100,}/, content,
      "[base64 image omitted]")
  end
  defp sanitize_content(other), do: inspect(other)

  defp format_tools([]), do: "(none)"
  defp format_tools(tools) do
    Enum.map_join(tools, ", ", fn t -> t[:name] || t["name"] || "?" end)
  end

  defp format_result({:ok, {:tool_calls, calls}}) do
    Enum.map_join(calls, "\n", fn c ->
      name = get_in(c, ["function", "name"]) || "?"
      args = get_in(c, ["function", "arguments"]) || %{}
      "tool_call: #{name}(#{inspect(args)})"
    end)
  end
  defp format_result({:ok, text}) when is_binary(text), do: text
  defp format_result({:error, reason}), do: "ERROR: #{inspect(reason)}"
  defp format_result(other), do: inspect(other)

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.slice(0, 19)
  end
end
