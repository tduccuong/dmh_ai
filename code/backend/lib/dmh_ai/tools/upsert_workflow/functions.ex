# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.Functions do
  @moduledoc """
  Function-existence check + closest-suggestion helpers for the
  `upsert_workflow` validator.

  Every `kind: "step"` node's `function:` must resolve to either
  the connector manifest (`<slug>.<fn>`) or a runtime synthetic
  primitive (`llm.compose`, `llm.summarise`, `builtin.coalesce`,
  `workflow.invoke`). Unknown names produce a teaching error with a
  per-slug shortlist of the actual registered functions, sorted by
  Jaro distance to the typo so the closest matches surface first.

  Also exports `is_step_node?/1` + `function_exists?/1` for sibling
  validators that need to filter step nodes or probe the manifest.
  """

  alias DmhAi.Connectors.Manifest, as: ConnectorManifest
  alias DmhAi.Tools.UpsertWorkflow.Synthetics

  @doc """
  Reject any step node whose `function:` neither resolves in the
  connector manifest nor matches a runtime synthetic. Produces a
  teaching error with closest matches for the slug.
  """
  @spec check_functions_exist([map()]) :: :ok | {:error, String.t()}
  def check_functions_exist(nodes) do
    nodes
    |> Enum.filter(&is_step_node?/1)
    |> Enum.reduce_while(:ok, fn node, _acc ->
      function_name = node["function"]
      cond do
        not is_binary(function_name) ->
          {:halt, {:error, "upsert_workflow: node #{node["id"]} `function` must be a string, got #{inspect(function_name)}"}}

        function_name in Synthetics.list() ->
          {:cont, :ok}

        function_exists?(function_name) ->
          {:cont, :ok}

        true ->
          {:halt,
           {:error, unknown_function_error(node["id"], function_name)}}
      end
    end)
  end

  @doc """
  Decide whether the node is a step that the validator should
  look at (kind=step with a function field present). Used by every
  pass that walks step nodes.
  """
  @spec is_step_node?(map()) :: boolean()
  def is_step_node?(node) do
    kind = Map.get(node, "kind", "step")
    kind == "step" and Map.has_key?(node, "function")
  end

  @doc """
  True when the connector manifest knows the FQN.
  """
  @spec function_exists?(any()) :: boolean()
  def function_exists?(function_name) when is_binary(function_name) do
    ConnectorManifest.lookup_fqn(function_name) != nil
  end
  def function_exists?(_), do: false

  # Build the unknown-function error with a per-slug shortlist of
  # the actual functions registered for the connector — sorted by
  # Jaro distance to the model's typo so the closest matches are
  # surfaced first. Catches the common failure mode where the model
  # invents a function name from the vendor's public REST docs
  # instead of the connector's manifest verbs.
  defp unknown_function_error(node_id, function_name) do
    [slug | _] = String.split(function_name, ".", parts: 2)
    suggestions = closest_functions_for_slug(slug, function_name, 10)

    "upsert_workflow: node #{node_id} references unknown function `#{function_name}` — " <>
      "not in any connector manifest, not a synthetic primitive. The DMH-AI primitives " <>
      "available to your workflow are EXACTLY the ones in your tool catalog. " <>
      suggestions_clause(slug, suggestions) <>
      "Two common confusions to avoid: " <>
      "(a) if this node should EMIT a literal value with no API call, use a node with " <>
      "`kind: 'output'` and an `emit: {<name>: <value>}` map — output nodes have no " <>
      "`function`/`args` field. " <>
      "(b) if you saw this function name in third-party platform documentation " <>
      "(vendor REST API path, public docs), that path is NOT a DMH-AI primitive unless a " <>
      "registered connector exposes it — your tool catalog is the only source of truth."
  end

  defp suggestions_clause(_slug, []), do: ""

  defp suggestions_clause(slug, names) do
    "Functions actually registered for `#{slug}` (closest matches first): " <>
      Enum.map_join(names, ", ", &("`" <> &1 <> "`")) <>
      ". Pick the one that performs this step's action. If NONE of them fits, this " <>
      "connector cannot do it — tell the user the capability is missing (suggest an " <>
      "alternative connector, a manual route, or proceeding without that part). These " <>
      "names are internal and complete: the real name lives ONLY in this list, so " <>
      "`web_search` / `fetch_index` (which index the public web) cannot surface one — " <>
      "resolve the step from the list above. "
  end

  # Pull every `<slug>.<function>` available for a slug from the
  # Universal-Region Dispatcher's manifest, dedupe, and sort by Jaro
  # distance to the model's typo. Returns up to `limit` names.
  defp closest_functions_for_slug(slug, target, limit) do
    dispatcher_names =
      case DmhAi.Tools.Dispatcher.lookup(slug) do
        {:ok, %{manifest: %{functions: functions}}} when is_map(functions) ->
          Enum.map(functions, fn {path, _} -> slug <> "." <> path end)

        _ ->
          []
      end

    Enum.uniq(dispatcher_names)
    |> Enum.sort_by(&String.jaro_distance(&1, target), :desc)
    |> Enum.take(limit)
  end
end
