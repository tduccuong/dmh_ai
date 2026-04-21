# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.Registry do
  @moduledoc """
  Lists all available tools and dispatches execute calls by name.
  """

  @tools [
    Dmhai.Tools.Plan,
    Dmhai.Tools.StepSignal,
    Dmhai.Tools.TaskSignal,
    Dmhai.Tools.WebSearch,
    Dmhai.Tools.WebFetch,
    Dmhai.Tools.RunScript,
    Dmhai.Tools.ReadFile,
    Dmhai.Tools.WriteFile,
    Dmhai.Tools.Calculator,
    Dmhai.Tools.ParseDocument,
    Dmhai.Tools.ExtractContent,
    Dmhai.Tools.SpawnTask
  ]

  @doc "Returns all tool definitions in OpenAI function-calling format."
  def all_definitions do
    Enum.map(@tools, & &1.definition())
  end

  @doc "Executes a tool by name. Returns {:ok, result} or {:error, reason}."
  def execute(name, args, context) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil -> {:error, "Unknown tool: #{inspect(name)}"}
      tool -> tool.execute(args, context)
    end
  end
end
