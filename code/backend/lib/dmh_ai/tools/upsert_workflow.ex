# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow do
  @moduledoc """
  Persist a compiled workflow as a new version. The only model-facing
  surface in the workflow layer's write path; arming + invocation
  are separate tools.

  Inputs:

    * `name`         — slug (lowercase alnum + underscore). Optional;
                       derived from `display_name` if omitted.
    * `display_name` — human label, e.g. "Customer onboarding from new deal".
    * `ir`           — full workflow IR (trigger, nodes, edges, outputs).
                       Schema per layer-W.md. Deep validation against
                       the connector function catalog lives in a
                       follow-up; v1 ships shape-only validation.
    * `change_note`  — one-line summary of what changed in this version
                       (used in the workflow viewer's title bar +
                       version-history breadcrumb).

  Returns `{:ok, %{name, version, url, display_name}}` — the chat
  reply renders `[<display_name> · v<version>](<url>)` as a markdown
  link the user can click to open the viewer modal.

  Org-scoping: the workflow lands under the caller's `org_id` (from
  `ctx.org_id`, falling back to `Constants.default_org_id/0` for the
  single-tenant install).
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Workflows
  alias DmhAi.Constants
  alias DmhAi.Connectors.Registry, as: ConnectorRegistry
  require Logger

  # Synthetic functions the compiler may emit even though they aren't
  # connector-backed. Validation passes them through; the runtime will
  # resolve them at execution time.
  @synthetic_functions ~w(llm.compose builtin.compute workflow.invoke)

  @impl true
  def name, do: "upsert_workflow"

  @impl true
  def description do
    "Save a compiled workflow as a new version under the current org. " <>
      "Bumps the version on every save; the first save lands at v0. " <>
      "Returns {name, version, url, display_name}; render the URL as " <>
      "a clickable markdown link in the chat reply so the user can " <>
      "open the workflow viewer modal."
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          display_name: %{
            type:        "string",
            description: "Human-readable name shown in the modal title and KB. 3-8 words; the user's language."
          },
          name: %{
            type:        "string",
            description: "URL-safe slug (lowercase alnum + underscore). Optional; derived from display_name if omitted. Once saved, this is the stable identifier across versions."
          },
          ir: %{
            type:        "object",
            description: "Full workflow IR per layer-W.md: top-level keys 'trigger', 'inputs', 'nodes', 'outputs'. Each node carries both 'function'/'args' (technical) AND 'label' (human-readable description) — the viewer's Technical tab shows the former, the Label tab the latter."
          },
          change_note: %{
            type:        "string",
            description: "One-line summary of what this version changes vs the prior one (e.g. 'added approval gate before node 7'). Stored alongside the version; shown in the viewer's version history."
          }
        },
        required: ["display_name", "ir", "change_note"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id    = Map.get(ctx, :user_id)
    session_id = Map.get(ctx, :session_id)
    org_id     = Map.get(ctx, :org_id) || Constants.default_org_id()

    with :ok                  <- require_string(user_id, "ctx.user_id"),
         :ok                  <- require_string(session_id, "ctx.session_id"),
         {:ok, display_name}  <- normalise_display_name(args["display_name"]),
         {:ok, slug}          <- normalise_slug(args["name"], display_name),
         {:ok, ir}            <- normalise_ir(args["ir"]),
         {:ok, change_note}   <- normalise_change_note(args["change_note"]),
         {:ok, oq_count}      <- count_open_questions(ir),
         {:ok, validated_ir}  <- shape_validate(ir) do

      params = %{
        org_id:               org_id,
        id:                   slug,
        display_name:         display_name,
        ir:                   validated_ir,
        change_note:          change_note,
        session_id:           session_id,
        user_id:              user_id,
        open_questions_count: oq_count
      }

      case Workflows.upsert(params) do
        {:ok, %{id: id, display_name: dn, version: v, url: url}} ->
          Logger.info("[UpsertWorkflow] saved slug=#{id} v#{v} oq=#{oq_count}")

          {:ok, %{
            "name"         => id,
            "display_name" => dn,
            "version"      => v,
            "url"          => url,
            "open_questions_count" => oq_count
          }}

        {:error, reason} ->
          {:error, "upsert_workflow: persist failed (#{inspect(reason)})"}
      end
    end
  end

  # ─── input normalisation ──────────────────────────────────────────────

  defp require_string(v, _label) when is_binary(v) and v != "", do: :ok
  defp require_string(_, label), do: {:error, "upsert_workflow: missing #{label}"}

  defp normalise_display_name(v) when is_binary(v) do
    trimmed = String.trim(v)
    if String.length(trimmed) >= 3 do
      {:ok, trimmed}
    else
      {:error, "upsert_workflow: display_name too short (need ≥ 3 chars)"}
    end
  end
  defp normalise_display_name(_),
    do: {:error, "upsert_workflow: display_name required (string)"}

  defp normalise_slug(nil, display_name), do: {:ok, Workflows.slugify(display_name)}
  defp normalise_slug("",  display_name), do: {:ok, Workflows.slugify(display_name)}
  defp normalise_slug(v,   _) when is_binary(v) do
    s = Workflows.slugify(v)
    if s == "" do
      {:error, "upsert_workflow: name produced empty slug after normalisation"}
    else
      {:ok, s}
    end
  end
  defp normalise_slug(_, _),
    do: {:error, "upsert_workflow: name must be a string when supplied"}

  defp normalise_ir(v) when is_map(v), do: {:ok, v}
  defp normalise_ir(_),
    do: {:error, "upsert_workflow: ir must be a JSON object (map)"}

  defp normalise_change_note(v) when is_binary(v) and v != "" do
    {:ok, String.slice(String.trim(v), 0, 280)}
  end
  defp normalise_change_note(nil), do: {:ok, "initial draft"}
  defp normalise_change_note(""),  do: {:ok, "initial draft"}
  defp normalise_change_note(_),
    do: {:error, "upsert_workflow: change_note must be a string"}

  # ─── shape validation ─────────────────────────────────────────────────
  # v1 is intentionally lenient: structural checks only (top-level keys
  # present, nodes have ids, ids are unique). Deep validation —
  # function-catalog membership, argument-type matching, Mustache
  # reference resolution — lands in chunk 2 alongside the compile-mode
  # system-prompt addendum.

  defp shape_validate(%{} = ir) do
    with :ok            <- check_top_level_keys(ir),
         {:ok, nodes}   <- check_nodes(ir),
         :ok            <- check_unique_ids(ir),
         :ok            <- check_functions_exist(nodes),
         :ok            <- check_required_args(nodes),
         :ok            <- check_references(ir, nodes) do
      {:ok, ir}
    end
  end

  # ─── deep validation: function catalog ─────────────────────────────────

  defp check_functions_exist(nodes) do
    nodes
    |> Enum.filter(&is_step_node?/1)
    |> Enum.reduce_while(:ok, fn node, _acc ->
      function_name = node["function"]
      cond do
        not is_binary(function_name) ->
          {:halt, {:error, "upsert_workflow: node #{node["id"]} `function` must be a string, got #{inspect(function_name)}"}}

        function_name in @synthetic_functions ->
          {:cont, :ok}

        function_exists?(function_name) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, "upsert_workflow: node #{node["id"]} references unknown function `#{function_name}` — not in any connector manifest, not a synthetic primitive"}}
      end
    end)
  end

  defp is_step_node?(node) do
    kind = Map.get(node, "kind", "step")
    kind == "step" and Map.has_key?(node, "function")
  end

  # Manifest keys are bare ("contact.find"); the IR namespaces them
  # ("hubspot.contact.find"). Strip the slug prefix to look up.
  defp function_exists?(function_name) when is_binary(function_name) do
    case String.split(function_name, ".", parts: 2) do
      [slug, bare] ->
        case ConnectorRegistry.module_for_slug(slug) do
          nil -> false
          mod ->
            try do
              Map.has_key?(mod.manifest().functions, bare)
            rescue _ -> false
            end
        end

      _ ->
        false
    end
  end

  # ─── deep validation: required args present ────────────────────────────

  defp check_required_args(nodes) do
    nodes
    |> Enum.filter(&is_step_node?/1)
    |> Enum.reject(fn n -> n["function"] in @synthetic_functions end)
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

  defp function_spec(function_name) when is_binary(function_name) do
    case String.split(function_name, ".", parts: 2) do
      [slug, bare] ->
        case ConnectorRegistry.module_for_slug(slug) do
          nil -> nil
          mod ->
            try do
              Map.get(mod.manifest().functions, bare)
            rescue _ -> nil
            end
        end

      _ ->
        nil
    end
  end

  # ─── deep validation: Mustache references resolve ──────────────────────
  # For every `{{<expr>}}` in any node's args:
  #   - `{{T.<path>}}` → root segment `T` is reserved; matches a trigger
  #     `inputs[]` entry by leading path segment.
  #   - `{{<id>.<field>}}` → some node with that id must exist (DAG
  #     ordering check is loose in v1 — same workflow, no forward refs
  #     beyond branches).
  #   - `{{now}}`, `{{today}}`, `{{org.<…>}}` — built-in bindings,
  #     allowed without further checks.

  @builtin_root_bindings ~w(now today org state)

  defp check_references(ir, nodes) do
    trigger_inputs   = ir |> Map.get("inputs", []) |> Enum.map(& &1["name"])
    declared_ids     = nodes |> Enum.map(& &1["id"])
    declared_emits   = collect_emits(nodes)

    refs =
      nodes
      |> Enum.flat_map(&extract_node_refs/1)

    refs
    |> Enum.reduce_while(:ok, fn {node_id, ref_path}, _acc ->
      case resolve_ref(ref_path, trigger_inputs, declared_ids, declared_emits) do
        :ok -> {:cont, :ok}
        {:error, why} -> {:halt, {:error, "upsert_workflow: node #{node_id} reference `{{#{ref_path}}}` — #{why}"}}
      end
    end)
  end

  defp collect_emits(nodes) do
    Enum.reduce(nodes, %{}, fn n, acc ->
      case Map.get(n, "emits") do
        e when is_map(e) -> Map.put(acc, n["id"], Map.keys(e))
        _                -> Map.put(acc, n["id"], [])
      end
    end)
  end

  defp extract_node_refs(node) do
    args = Map.get(node, "args", %{})
    walk_value(args)
    |> Enum.map(fn ref -> {node["id"], ref} end)
  end

  defp walk_value(v) when is_binary(v) do
    Regex.scan(~r/\{\{([^}]+)\}\}/, v, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp walk_value(v) when is_map(v) do
    v |> Map.values() |> Enum.flat_map(&walk_value/1)
  end

  defp walk_value(v) when is_list(v) do
    Enum.flat_map(v, &walk_value/1)
  end

  defp walk_value(_), do: []

  defp resolve_ref(ref, trigger_inputs, declared_ids, declared_emits) do
    case String.split(ref, ".", parts: 2) do
      ["T", path] ->
        first = path |> String.split(".") |> List.first()
        cond do
          # Match by leading segment OR full path (inputs may declare
          # nested paths like "deal.id" — both are acceptable).
          Enum.any?(trigger_inputs, fn n -> n == path or String.starts_with?(path, n <> ".") or n == first end) ->
            :ok

          true ->
            {:error, "no matching trigger input (declared: #{inspect(trigger_inputs)})"}
        end

      [root, _rest] when root in @builtin_root_bindings ->
        :ok

      [id_str, field] ->
        case Integer.parse(id_str) do
          {id, ""} ->
            cond do
              not Enum.member?(declared_ids, id) ->
                {:error, "node id #{id} not declared"}

              not Enum.member?(Map.get(declared_emits, id, []), field |> String.split(".") |> List.first()) ->
                {:error, "node #{id} doesn't declare emit `#{field}`"}

              true ->
                :ok
            end

          _ ->
            # Non-integer root — treat as built-in/free-form helper (e.g. `now_plus_days(7)`).
            :ok
        end

      [_single] ->
        # Bare reference like `{{now}}` is allowed.
        :ok

      _ ->
        {:error, "malformed reference"}
    end
  end

  defp check_top_level_keys(ir) do
    cond do
      not is_map(Map.get(ir, "trigger")) ->
        {:error, "upsert_workflow: ir.trigger missing or not an object"}

      not is_list(Map.get(ir, "nodes")) ->
        {:error, "upsert_workflow: ir.nodes missing or not an array"}

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

  defp count_open_questions(ir) do
    list = Map.get(ir, "open_questions", [])
    if is_list(list), do: {:ok, length(list)}, else: {:ok, 0}
  end
end
