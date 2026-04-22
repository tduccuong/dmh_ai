# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.Registry do
  @moduledoc """
  Lists all available tools and dispatches execute calls by name.
  """

  @tools [
    Dmhai.Tools.CreateTask,
    Dmhai.Tools.UpdateTask,
    Dmhai.Tools.FetchTask,
    Dmhai.Tools.WebSearch,
    Dmhai.Tools.WebFetch,
    Dmhai.Tools.RunScript,
    Dmhai.Tools.ReadFile,
    Dmhai.Tools.WriteFile,
    Dmhai.Tools.Calculator,
    Dmhai.Tools.ParseDocument,
    Dmhai.Tools.ExtractContent,
    Dmhai.Tools.SpawnTask,
    Dmhai.Tools.SaveCredential,
    Dmhai.Tools.LookupCredential
  ]

  @doc "Returns all tool definitions in OpenAI function-calling format."
  def all_definitions do
    Enum.map(@tools, & &1.definition())
  end

  @doc "List of all tool names known to the registry."
  @spec names() :: [String.t()]
  def names do
    Enum.map(@tools, & &1.name())
  end

  @doc "True if the given name corresponds to a registered tool."
  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name), do: name in names()
  def known?(_), do: false

  @doc "Executes a tool by name. Returns {:ok, result} or {:error, reason}."
  def execute(name, args, context) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil -> {:error, "Unknown tool: #{inspect(name)}"}
      tool -> tool.execute(args, context)
    end
  end
end
