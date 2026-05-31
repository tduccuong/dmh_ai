# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.Shape do
  @moduledoc """
  Top-level IR shape + trigger / output node shape. Cheap
  structural checks the validator runs before the deeper passes
  (functions, required args, references, provenance, ...) so we
  bail with a precise error if the IR's bones are wrong.

  Owns:
    * `shape_validate/1` — structural chain: top-level keys → nodes
      present → unique ids → trigger node count → output node
      shape. Returns `{:ok, nodes}` (the materialised list) for the
      shell to pass into the deeper passes.
    * `check_trigger_node/1` — exactly one `kind: "trigger"` node.
    * `check_output_node_shape/1` — output nodes carry `emit:` and
      none of the step-family keys.
  """

  @doc """
  Structural validation chain. Returns `{:ok, nodes}` on success —
  the materialised node list the shell threads into deeper passes.
  """
  @spec shape_validate(map()) :: {:ok, [map()]} | {:error, String.t()}
  def shape_validate(%{} = ir) do
    with :ok          <- check_top_level_keys(ir),
         {:ok, nodes} <- check_nodes(ir),
         :ok          <- check_unique_ids(ir),
         :ok          <- check_trigger_node(nodes),
         :ok          <- check_output_node_shape(nodes) do
      {:ok, nodes}
    end
  end

  @doc """
  Every workflow MUST have exactly one trigger node. The trigger
  node carries when/where/how the run starts (kind: manual /
  schedule / poll / webhook), the `inputs[]` declaration that
  populates the `{{T.<field>}}` binding namespace, and `next: <id>`
  pointing at the first executable node.
  """
  @spec check_trigger_node([map()]) :: :ok | {:error, String.t()}
  def check_trigger_node(nodes) do
    triggers = Enum.filter(nodes, fn n -> n["kind"] == "trigger" end)

    case triggers do
      [] ->
        {:error,
         "upsert_workflow: IR has no trigger node. Every workflow needs " <>
           "exactly one node with `kind: 'trigger'` declaring how the run " <>
           "starts (`trigger_kind: 'manual' | 'schedule' | 'poll' | " <>
           "'webhook'`), its `inputs[]`, and `next: <first_step_id>`."}

      [_] ->
        :ok

      many ->
        ids = Enum.map(many, & &1["id"])
        {:error,
         "upsert_workflow: IR has #{length(many)} trigger nodes " <>
           "(#{inspect(ids)}). Exactly one is allowed."}
    end
  end

  @doc """
  `output` nodes carry a literal/binding `emit` map and NOTHING
  else from the step family — no `function`, no `args`, no
  `steps[]`. The model often confuses "emit this string" with "call
  a function that emits"; reject early with a teaching error so it
  self-corrects on refinement.
  """
  @spec check_output_node_shape([map()]) :: :ok | {:error, String.t()}
  def check_output_node_shape(nodes) do
    nodes
    |> Enum.filter(fn n -> n["kind"] == "output" end)
    |> Enum.reduce_while(:ok, fn node, _acc ->
      cond do
        not is_map(node["emit"]) ->
          {:halt,
           {:error,
            "upsert_workflow: node #{node["id"]} (kind=output) must declare " <>
              "an `emit: {<name>: <literal or {{binding}}>}` map. Output " <>
              "nodes terminate the run by writing this map to the result; " <>
              "they don't have a `function` or `args` field."}}

        Map.has_key?(node, "function") or Map.has_key?(node, "args") or Map.has_key?(node, "steps") ->
          {:halt,
           {:error,
            "upsert_workflow: node #{node["id"]} (kind=output) cannot have " <>
              "`function`, `args`, or `steps`. Output nodes are terminal — " <>
              "they only emit a map. To call a tool first and then return " <>
              "its result, use a `step` node followed by an `output` node " <>
              "that binds to the step's emit."}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # Trigger config used to be a top-level `trigger: {...}` field;
  # it's now a node with `kind: "trigger"` inside `nodes[]`. The
  # only required top-level field is `nodes`. `outputs[]` is
  # optional (a workflow can write its result via output-node
  # emits without an explicit outputs[] declaration).
  defp check_top_level_keys(ir) do
    cond do
      not is_list(Map.get(ir, "nodes")) ->
        {:error, "upsert_workflow: ir.nodes missing or not an array"}

      # A non-empty top-level `inputs` is a real misuse — the model is
      # declaring inputs at the wrong level. An EMPTY top-level
      # `inputs: []` is benign noise (no other pass reads it) and the
      # model emits it naturally from input-shaped schemas, so we
      # silently tolerate it instead of failing the whole upsert.
      match?(list when is_list(list) and list != [], Map.get(ir, "inputs")) ->
        {:error,
         "upsert_workflow: IR has a non-empty top-level `inputs` array. Trigger " <>
           "inputs belong on the TRIGGER node, not at the IR root. Move the array " <>
           "into the trigger node's `inputs` field: " <>
           "`{id: 0, kind: \"trigger\", trigger_kind: \"manual\", " <>
           "inputs: [...], next: 1}`. The IR root only accepts `nodes` " <>
           "(required) and `outputs` (optional, names workflow-level outputs)."}

      true ->
        :ok
    end
  end

  defp check_nodes(ir) do
    nodes = Map.get(ir, "nodes", [])

    cond do
      nodes == [] ->
        {:error, "upsert_workflow: ir.nodes must contain at least one node"}

      Enum.any?(nodes, fn n -> not is_map(n) or not Map.has_key?(n, "id") end) ->
        {:error, "upsert_workflow: every node must be an object with an `id` field"}

      true ->
        {:ok, nodes}
    end
  end

  defp check_unique_ids(ir) do
    ids = ir |> Map.get("nodes", []) |> Enum.map(& &1["id"])
    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      dupes = ids -- Enum.uniq(ids)
      {:error, "upsert_workflow: duplicate node ids: #{inspect(dupes)}"}
    end
  end
end
