# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Police.ToolName do
  @moduledoc """
  Per-tool-call gate: reject when the emitted `name` doesn't correspond
  to a registered tool. Guards against model output malformation where
  the model stuffs garbled or hallucinated content into `function.name`.

  The rejection message enumerates the valid tool names so the
  next-turn corrective tool_result gives the model the concrete
  vocabulary to recover with.
  """

  require Logger

  alias DmhAi.Tools.Registry

  @doc """
  Validate that `name` is a registered tool. The single-arg variant is
  equivalent to the 2-arg variant with `user_id = nil` — used by
  callers that don't have a user context (built-in tool universe only).
  """
  @spec check_tool_name_validity(String.t()) :: :ok | {:rejected, {atom(), String.t()}}
  def check_tool_name_validity(name) when is_binary(name), do: check_tool_name_validity(name, nil)

  def check_tool_name_validity(_),
    do: {:rejected, {:unknown_tool_name, "Error: tool_call `function.name` must be a string."}}

  @doc """
  Includes the MCP tools attached to the user's current session in the
  validity check so `<alias>.<tool>` names registered via `connect_mcp`
  are accepted.
  """
  @spec check_tool_name_validity(String.t(), String.t() | nil) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_tool_name_validity(name, user_id) when is_binary(name) do
    if Registry.known?(name, user_id) do
      :ok
    else
      name_preview = String.slice(name, 0, 120)

      valid_names = Registry.names(user_id)

      reason = unknown_tool_name_reason(name_preview, valid_names)

      Logger.warning("[Police] REJECTED unknown_tool_name: name=#{inspect(String.slice(name, 0, 200))}")
      DmhAi.SysLog.log("[POLICE] REJECTED unknown_tool_name: name=#{inspect(String.slice(name, 0, 200))}")
      {:rejected, {:unknown_tool_name, reason}}
    end
  end

  def check_tool_name_validity(_, _),
    do: {:rejected, {:unknown_tool_name, "Error: tool_call `function.name` must be a string."}}

  # MCP-attached tools live under `<alias>.<tool>`. When a name has
  # that shape but isn't in the catalog, the most likely cause is
  # the model is reaching for a service that hasn't been attached
  # yet. Lead with that hint instead of the bare tool list.
  defp unknown_tool_name_reason(name_preview, valid_names) do
    case String.split(name_preview, ".", parts: 2) do
      [alias_, _tool] when alias_ != "" ->
        "Error: `#{name_preview}` is not currently attached. Namespaced tools " <>
          "(`<alias>.<tool>`) come from external services attached via `connect_mcp`. " <>
          "If you want to use `#{alias_}` here, call `connect_mcp` first with the server's " <>
          "URL.\n\n" <>
          "Tools currently available: " <> Enum.join(valid_names, ", ") <> "."

      _ ->
        "Error: `#{name_preview}` is not a valid tool name. Pick one of: " <>
          Enum.join(valid_names, ", ") <>
          ". Each tool_call must have a plain tool name in the `function.name` field and the " <>
          "arguments as a JSON object in `function.arguments`. Retry with the correct structure."
    end
  end
end
