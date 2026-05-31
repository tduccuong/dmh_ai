# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.RequiredArgs do
  @moduledoc """
  Required-args check: every step node MUST declare all required
  args from its function's manifest, and MUST NOT declare args the
  manifest doesn't know about. Synthetic primitives are skipped —
  their args are validated by the runtime.

  Also exports `function_spec/1` so sibling validators can pull a
  function's manifest entry without re-aliasing `ConnectorManifest`.
  """

  alias DmhAi.Connectors.Manifest, as: ConnectorManifest
  alias DmhAi.Tools.UpsertWorkflow.{Functions, Synthetics}

  @doc """
  Reject step nodes missing a required arg or carrying an arg the
  function manifest doesn't declare.
  """
  @spec check_required_args([map()]) :: :ok | {:error, String.t()}
  def check_required_args(nodes) do
    nodes
    |> Enum.filter(&Functions.is_step_node?/1)
    |> Enum.reject(fn n -> n["function"] in Synthetics.list() end)
    |> Enum.reduce_while(:ok, fn node, _acc ->
      case function_spec(node["function"]) do
        nil ->
          # Already caught by check_functions_exist; defensive skip.
          {:cont, :ok}

        %{args: arg_schema} ->
          declared = Map.keys(Map.get(node, "args", %{}))
          required = arg_schema
                     |> Enum.filter(fn {_k, v} -> Map.get(v, :required) == true end)
                     |> Enum.map(fn {k, _v} -> k end)

          missing = required -- declared
          unknown = declared -- Map.keys(arg_schema)

          cond do
            missing != [] ->
              {:halt, {:error, "upsert_workflow: node #{node["id"]} (`#{node["function"]}`) missing required args: #{inspect(missing)}"}}

            unknown != [] ->
              {:halt, {:error, "upsert_workflow: node #{node["id"]} (`#{node["function"]}`) declares args not in the function manifest: #{inspect(unknown)}"}}

            true ->
              {:cont, :ok}
          end
      end
    end)
  end

  @doc """
  Resolve a function's manifest entry (`%{args: …, returns: …,
  scopes_required: …, …}`) or nil. Exposed so sibling validators
  (Provenance, References, Scopes) can pull the spec without a
  second ConnectorManifest alias.
  """
  @spec function_spec(any()) :: map() | nil
  def function_spec(function_name) when is_binary(function_name) do
    ConnectorManifest.lookup_fqn(function_name)
  end
  def function_spec(_), do: nil
end
