# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.BranchPredicates do
  @moduledoc """
  Branch predicate grammar gate.

  Every `branch.cases[].when` must parse as a single comparison
  expression under the `DmhAi.Workflows.Expression` grammar:

      <operand> <op> <operand>

  where `<op> ∈ { ==  !=  <  >  <=  >= }` and operands are
  bindings (`{{T.x}}`, `{{1.field}}`), literals (numbers, quoted
  strings, booleans), or `null`.

  Rejects every malformed entry with the parser's own error
  sentence — which already includes examples. Catches the failure
  mode where the model writes natural-language predicates
  (`"no contacts found"`) or bare bindings
  (`"{{1.contacts.length}}"`) and expects the executor to interpret
  them.
  """

  alias DmhAi.Workflows.Expression

  @doc """
  Walk every branch node and reject the first invalid `when:`
  predicate with the parser's diagnostic.
  """
  @spec check_branch_predicates([map()]) :: :ok | {:error, String.t()}
  def check_branch_predicates(nodes) do
    nodes
    |> Enum.filter(fn n -> n["kind"] == "branch" end)
    |> Enum.reduce_while(:ok, fn node, _acc ->
      case scan_branch_predicates(node) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Parse every `cases[].when` on a single branch node; first failure
  surfaces with the parser's `why` plus the offending case index.
  """
  @spec scan_branch_predicates(map()) :: :ok | {:error, String.t()}
  def scan_branch_predicates(node) do
    cases = Map.get(node, "cases", []) || []

    cases
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {kase, idx}, _acc ->
      pred = Map.get(kase, "when")

      case Expression.parse(pred) do
        {:ok, _ast} ->
          {:cont, :ok}

        {:error, why} ->
          {:halt,
           {:error,
            "upsert_workflow: node #{node["id"]} branch case[#{idx}] " <>
              "has an invalid `when:` predicate. #{why}"}}
      end
    end)
  end
end
