defmodule Dmhai.Tools.Behaviour do
  @moduledoc """
  Behaviour all tools must implement.
  """

  @doc "Unique tool name used in LLM function calls"
  @callback name() :: String.t()

  @doc "Human-readable description for the tool registry"
  @callback description() :: String.t()

  @doc "OpenAI-compatible function definition for the LLM"
  @callback definition() :: map()

  @doc "Execute the tool with parsed args and user context"
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, String.t()}
end
