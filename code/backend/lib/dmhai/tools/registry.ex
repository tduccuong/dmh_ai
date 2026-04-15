defmodule Dmhai.Tools.Registry do
  @moduledoc """
  Lists all available tools and dispatches execute calls by name.
  """

  @tools [
    Dmhai.Tools.WebFetch,
    Dmhai.Tools.Bash,
    Dmhai.Tools.ReadFile,
    Dmhai.Tools.WriteFile,
    Dmhai.Tools.ListDir,
    Dmhai.Tools.DatetimeTool,
    Dmhai.Tools.Calculator
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
