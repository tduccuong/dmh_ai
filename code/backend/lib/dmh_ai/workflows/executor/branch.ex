# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.Branch do
  @moduledoc """
  Branch-node handler. Walks the IR's `cases[]`, picks the first whose
  `when` predicate evaluates true, and continues to its `next`. Falls
  through to `else.next` when no case matches.

  Predicate evaluation is delegated to `DmhAi.Workflows.Expression`,
  with the executor's `Bindings.resolve_ref_body/2` as the lookup
  callback so the same ref grammar (`{{T.foo}}`, `{{N.bar}}`,
  `{{owner.email}}`, …) resolves under predicates as it does under
  args.
  """

  alias DmhAi.Workflows
  alias DmhAi.Workflows.Executor
  alias DmhAi.Workflows.Executor.Bindings

  @doc """
  Top-level branch handler invoked by the walker's `dispatch_node/4`.
  """
  def handle_branch(ir, node, state, n) do
    step_id = Workflows.open_step(state.id, node["id"],
      %{cases: Map.get(node, "cases", []), else: Map.get(node, "else")})

    {next_id, matched_when} =
      case pick_branch(node["cases"] || [], state) do
        nil ->
          else_next =
            case Map.get(node, "else") do
              %{"next" => nid} -> nid
              _ -> nil
            end

          {else_next, nil}

        %{"next" => nid, "when" => w} ->
          {nid, w}

        %{"next" => nid} ->
          {nid, nil}
      end

    Workflows.close_step(step_id, :completed,
      output: %{branched_to_node: next_id, matched_when: matched_when})

    next = Executor.find_node_by_id(ir, next_id)
    Executor.walk(ir, next, state, n + 1)
  end

  defp pick_branch([], _state), do: nil

  defp pick_branch([%{"when" => predicate} = c | rest], state) do
    if eval_predicate(predicate, state), do: c, else: pick_branch(rest, state)
  end

  defp pick_branch([%{"else" => _} | _], _state), do: nil

  defp pick_branch([_ | rest], state), do: pick_branch(rest, state)

  # Predicate evaluation uses the dedicated `DmhAi.Workflows.Expression`
  # parser. Compile-time validator (`upsert_workflow.ex
  # check_branch_predicates/1`) has already rejected malformed
  # expressions, so we expect `parse/1` to succeed; the bare-parse
  # rescue below handles the residual edge where state-injected
  # bindings produced an unparseable string.
  defp eval_predicate(pred, state) when is_binary(pred) do
    case DmhAi.Workflows.Expression.parse(pred) do
      {:ok, ast} ->
        DmhAi.Workflows.Expression.evaluate(ast, fn path ->
          Bindings.resolve_ref_body(path, state)
        end)

      {:error, _} ->
        false
    end
  end

  defp eval_predicate(_, _), do: false
end
