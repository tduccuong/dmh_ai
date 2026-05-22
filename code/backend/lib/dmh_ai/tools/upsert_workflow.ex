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
    * `description`  — one or two operator-readable sentences
                       describing WHAT the workflow does. The
                       picker shows this for the latest version
                       (the only runnable one); SME staff use it
                       to recognise the workflow at a glance.
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

  alias DmhAi.{Workflows, Constants, Permissions}
  alias DmhAi.Tools.Catalog
  alias DmhAi.Connectors.Manifest, as: ConnectorManifest
  require Logger

  # Synthetic functions the compiler may emit even though they aren't
  # connector-backed. Validation passes them through; the runtime will
  # resolve them at execution time.
  @synthetic_functions ~w(llm.compose llm.summarise builtin.compute builtin.coalesce workflow.invoke)

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
          description: %{
            type:        "string",
            description: "One or two short sentences describing WHAT this workflow does, written for an SME staff user who doesn't know the IR — what it acts on, what it produces, when to use it. Avoid implementation details (function names, node ids). 10-280 chars. The picker shows this exact text alongside the display_name."
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
        required: ["display_name", "description", "ir", "change_note"]
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
         {:ok, description}   <- normalise_description(args["description"]),
         {:ok, ir}            <- normalise_ir(args["ir"]),
         {:ok, change_note}   <- normalise_change_note(args["change_note"]),
         {:ok, validated_ir}  <- shape_validate(ir),
         {:ok, owner_id}      <- resolve_owner(org_id, slug, user_id),
         :ok                  <- check_permissions(validated_ir, owner_id),
         :ok                  <- check_scopes(validated_ir, owner_id) do

      params = %{
        org_id:       org_id,
        id:           slug,
        display_name: display_name,
        description:  description,
        ir:           validated_ir,
        change_note:  change_note,
        session_id:   session_id,
        user_id:      user_id
      }

      case Workflows.upsert(params) do
        {:ok, %{id: id, display_name: dn, version: v, url: url, created_by: owner}} ->
          Logger.info("[UpsertWorkflow] saved slug=#{id} v#{v} owner=#{owner}")

          {:ok, %{
            "name"         => id,
            "display_name" => dn,
            "version"      => v,
            "url"          => url,
            "created_by"   => owner
          }}

        {:error, reason} ->
          {:error, "upsert_workflow: persist failed (#{inspect(reason)})"}
      end
    end
  end

  # ─── permission pass (Phase B) ────────────────────────────────────────
  # For every step in the IR, look up its manifest in Tools.Catalog and
  # call Permissions.can?(owner, action, target). Owner is workflows.created_by
  # (the caller on first save, the existing owner on edits). Failure
  # returns a structured envelope the chat can render as a
  # request_input for the user to pick a remediation.

  defp resolve_owner(org_id, slug, caller_user_id) do
    case Workflows.get_workflow(org_id, slug) do
      nil -> {:ok, caller_user_id}                       # first save → caller is owner
      %{created_by: owner} -> {:ok, owner}                # edit → owner is immutable
    end
  end

  defp check_permissions(ir, owner_id) do
    step_nodes =
      ir
      |> Map.get("nodes", [])
      |> Enum.filter(&is_step_node?/1)

    Enum.reduce_while(step_nodes, :ok, fn node, _acc ->
      fn_name      = node["function"]
      act_as       = node["act_as_user_id"]
      target_user  = act_as || owner_id

      case Catalog.lookup(fn_name) do
        {:ok, m} ->
          ctx = %{user_id: owner_id, act_as_user_id: act_as}
          args = Map.get(node, "args", %{})
          target =
            try do
              m.permission_target_fn.(args, %{user_id: target_user, act_as_user_id: act_as})
            rescue
              _ -> "creds:?:#{target_user}"
            end

          if Permissions.can?(owner_id, m.permission, target) do
            {:cont, :ok}
          else
            denial = Permissions.denial(owner_id, m.permission, target)
            {:halt, {:error, format_denial(node, fn_name, denial, ctx)}}
          end

        {:error, :unknown} ->
          if fn_name in @synthetic_functions do
            {:cont, :ok}
          else
            # check_functions_exist already catches truly-unknown
            # functions; this path is defensive.
            {:cont, :ok}
          end
      end
    end)
  end

  defp format_denial(node, fn_name, %Permissions.Denial{} = d, _ctx) do
    remediation = Enum.map(d.remediation, fn {kind, text} -> "#{kind}: #{text}" end)
    "upsert_workflow: permission_denied at node #{node["id"]} (`#{fn_name}`). " <>
      "owner=#{d.caller_user_id} action=#{d.action} target=#{d.target} reason=#{d.reason}. " <>
      "Remediation: " <> Enum.join(remediation, "; ")
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

  @description_min 10
  @description_max 280

  defp normalise_description(v) when is_binary(v) do
    trimmed = String.trim(v)
    len = String.length(trimmed)

    cond do
      len < @description_min ->
        {:error,
         "upsert_workflow: description too short " <>
           "(got #{len} chars, need ≥ #{@description_min}). " <>
           "Write one or two operator-readable sentences describing WHAT the workflow does."}

      len > @description_max ->
        {:error,
         "upsert_workflow: description too long " <>
           "(got #{len} chars, max #{@description_max}). " <>
           "Keep it to one or two short sentences."}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalise_description(_),
    do: {:error,
         "upsert_workflow: description required (string, " <>
           "#{@description_min}-#{@description_max} chars). " <>
           "Write one or two operator-readable sentences describing WHAT the workflow does."}

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
         :ok            <- check_trigger_node(nodes),
         :ok            <- check_output_node_shape(nodes),
         :ok            <- check_functions_exist(nodes),
         :ok            <- check_poll_trigger_manifest(nodes),
         :ok            <- check_trigger_cadence(nodes),
         :ok            <- check_required_args(nodes),
         :ok            <- check_references(ir, nodes),
         :ok            <- check_arg_provenance(nodes),
         :ok            <- check_branch_predicates(nodes) do
      {:ok, ir}
    end
  end

  # Every workflow MUST have exactly one trigger node. The trigger
  # node carries when/where/how the run starts (kind: manual /
  # schedule / poll / webhook), the `inputs[]` declaration that
  # populates the `{{T.<field>}}` binding namespace, and `next: <id>`
  # pointing at the first executable node.
  defp check_trigger_node(nodes) do
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

  # `output` nodes carry a literal/binding `emit` map and NOTHING
  # else from the step family — no `function`, no `args`, no
  # `steps[]`. The model often confuses "emit this string" with "call
  # a function that emits"; reject early with a teaching error so it
  # self-corrects on refinement.
  defp check_output_node_shape(nodes) do
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
          {:halt,
           {:error,
            "upsert_workflow: node #{node["id"]} references unknown function " <>
              "`#{function_name}` — not in any connector manifest, not a " <>
              "synthetic primitive. The DMH-AI primitives available to your " <>
              "workflow are EXACTLY the ones in your tool catalog; nothing " <>
              "else. Two common confusions to avoid: " <>
              "(a) if this node should EMIT a literal value with no API " <>
              "call, use a node with `kind: 'output'` and an `emit: {<name>: " <>
              "<value>}` map — output nodes have no `function`/`args` field. " <>
              "(b) if you saw this function name in third-party platform " <>
              "documentation (Bitrix24, Salesforce, custom REST API, …), " <>
              "that platform's API is NOT a DMH-AI primitive unless a " <>
              "registered connector exposes it — your tool catalog is the " <>
              "only source of truth for what's callable here."}}
      end
    end)
  end

  defp is_step_node?(node) do
    kind = Map.get(node, "kind", "step")
    kind == "step" and Map.has_key?(node, "function")
  end

  defp function_exists?(function_name) when is_binary(function_name) do
    ConnectorManifest.lookup_fqn(function_name) != nil
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
    ConnectorManifest.lookup_fqn(function_name)
  end

  # ─── L1 — Arg provenance enforcement ──────────────────────────────────
  #
  # See `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency / L1.
  # Each connector function's manifest may annotate required args with a
  # `provenance:` clause stating WHERE the value must come from at IR
  # write time. The validator enforces that clause — the runtime can
  # then rely on every required value tracing to a known source instead
  # of relying on regex heuristics to spot placeholders.
  #
  # Provenance kinds:
  #   :from_user        → value MUST be `{{T.<x>}}` (trigger input). No
  #                       literal allowed; the user supplies the value at
  #                       invoke time. Forces the model to declare a
  #                       trigger input or ask the user.
  #   :lookup           → value MUST be `{{<N>.<field>}}` (an upstream
  #                       step's emit). The model can't satisfy the
  #                       requirement by inventing a literal.
  #   :built_in         → value MUST equal the named built-in binding.
  #   :literal_default  → literals are acceptable (the connector author
  #                       has decided this arg is configuration the
  #                       workflow author legitimately bakes in).
  #
  # Default when no annotation: `:literal_default` (permissive). Connector
  # authors opt INTO strict enforcement by annotating `from_user` /
  # `lookup` / `built_in` per arg. This lets the spec land incrementally
  # — each connector's annotation surface grows over time without
  # breaking workflows that legitimately use literals on un-annotated args.

  defp check_arg_provenance(nodes) do
    nodes
    |> Enum.filter(&is_step_node?/1)
    |> Enum.reject(fn n -> n["function"] in @synthetic_functions end)
    |> Enum.reduce_while(:ok, fn node, _acc ->
      case scan_node_provenance(node) do
        :ok ->
          {:cont, :ok}

        {:provenance_error, arg_name, prov, value} ->
          {:halt,
           {:error,
            "upsert_workflow: node #{node["id"]} (`#{node["function"]}`) required arg " <>
              "`#{arg_name}` violates its declared provenance " <>
              "(#{inspect(prov)}). Got value: #{inspect(value)}. " <>
              provenance_advice(prov)}}
      end
    end)
  end

  defp scan_node_provenance(node) do
    case function_spec(node["function"]) do
      %{args: arg_schema} when is_map(arg_schema) ->
        args = Map.get(node, "args", %{})

        arg_schema
        |> Enum.filter(fn {_k, meta} -> Map.get(meta, :required) == true end)
        |> Enum.find_value(:ok, fn {arg_name, arg_meta} ->
          prov = Map.get(arg_meta, :provenance, %{kind: :literal_default})
          value = Map.get(args, to_string(arg_name))

          case validate_value_provenance(value, prov) do
            :ok -> nil
            :error -> {:provenance_error, arg_name, prov, value}
          end
        end)

      _ ->
        :ok
    end
  end

  # Permissive default — literals + bindings all pass. The connector
  # author opted not to constrain this arg.
  defp validate_value_provenance(_value, %{kind: :literal_default}), do: :ok
  defp validate_value_provenance(_value, %{kind: kind}) when kind == nil, do: :ok

  # `:from_user` — value MUST be a `{{T.<x>}}` trigger-input binding.
  # Literals are forbidden because they freeze the workflow at one
  # invented value; the user should supply this at each invocation.
  defp validate_value_provenance(value, %{kind: :from_user}) when is_binary(value) do
    if String.starts_with?(value, "{{T.") and String.ends_with?(value, "}}"),
      do: :ok,
      else: :error
  end

  defp validate_value_provenance(_value, %{kind: :from_user}), do: :error

  # `:lookup` — value MUST come from an upstream emit (`{{<N>.<field>}}`).
  # Trigger inputs are forbidden because the user typically doesn't know
  # vendor-internal ids (HubSpot's `contact_id`, Outlook's `event_id`);
  # they know emails, names, URLs. Forcing the upstream-step path means
  # the workflow ALWAYS resolves ids from human-friendly input via the
  # declared `source` finder verb. The upstream step's own provenance is
  # enforced recursively when we visit that node.
  defp validate_value_provenance(value, %{kind: :lookup}) when is_binary(value) do
    if String.match?(value, ~r/^\{\{\d+\..+\}\}$/), do: :ok, else: :error
  end

  defp validate_value_provenance(_value, %{kind: :lookup}), do: :error

  # `:built_in` — value MUST equal the named binding.
  defp validate_value_provenance(value, %{kind: :built_in, binding: binding}),
    do: if(value == binding, do: :ok, else: :error)

  defp validate_value_provenance(_value, _), do: :ok

  defp provenance_advice(%{kind: :from_user}),
    do: "This arg holds user-supplied data — declare a matching trigger input " <>
        "(`inputs: [{name: \"<arg>\", type: ...}]`) on the trigger node and bind " <>
        "the step's arg to `{{T.<arg>}}`. The user supplies the value at each " <>
        "invocation. If the value is genuinely fixed for every run, ask the user " <>
        "whether to bake it as a literal — and tell the connector author to annotate " <>
        "the arg as `provenance: %{kind: :literal_default}`."

  defp provenance_advice(%{kind: :lookup, source: source}),
    do: "This arg is the id of a vendor object the user doesn't know directly. " <>
        "Add an upstream step calling `#{source}` (driven by a human-friendly " <>
        "input like email/name/URL via its `query` arg) and bind this arg to " <>
        "`{{<that_node_id>.<field>}}`. A trigger input `{{T.<x>}}` is NOT a " <>
        "valid shortcut — the user typically doesn't know vendor-internal ids."

  defp provenance_advice(%{kind: :lookup}),
    do: "This arg must come from an upstream step's emit (`{{<N>.<field>}}`), " <>
        "not from a trigger input or a literal — the user doesn't know vendor " <>
        "ids directly."

  defp provenance_advice(%{kind: :built_in, binding: binding}),
    do: "This arg must be the built-in binding `#{binding}`."

  defp provenance_advice(_),
    do: "Pick a binding that matches the arg's declared provenance."

  # ─── Branch predicate grammar ─────────────────────────────────────────
  #
  # Every `branch.cases[].when` must parse as a single comparison
  # expression under the `DmhAi.Workflows.Expression` grammar:
  #     <operand> <op> <operand>
  # where `<op> ∈ { ==  !=  <  >  <=  >= }` and operands are
  # bindings (`{{T.x}}`, `{{1.field}}`), literals (numbers, quoted
  # strings, booleans), or `null`.
  #
  # The validator parses every `when:` and rejects malformed entries
  # with the parser's own error sentence — which already includes
  # examples. Catches the failure mode where the model writes
  # natural-language predicates (`"no contacts found"`) or bare
  # bindings (`"{{1.contacts.length}}"`) and expects the executor to
  # interpret them.

  defp check_branch_predicates(nodes) do
    nodes
    |> Enum.filter(fn n -> n["kind"] == "branch" end)
    |> Enum.reduce_while(:ok, fn node, _acc ->
      case scan_branch_predicates(node) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp scan_branch_predicates(node) do
    cases = Map.get(node, "cases", []) || []

    cases
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {kase, idx}, _acc ->
      pred = Map.get(kase, "when")

      case DmhAi.Workflows.Expression.parse(pred) do
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

  # ─── L3 — Compile-time scope gate ─────────────────────────────────────
  #
  # See `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency / L3.
  # Union the OAuth scopes every step's function requires; compare
  # against the user's current grant per slug. Missing scopes means
  # the workflow would silently `needs_auth` on its first armed fire —
  # reject the save and tell the user to reconnect.

  defp check_scopes(ir, owner_id) when is_binary(owner_id) do
    requirements =
      ir
      |> Map.get("nodes", [])
      |> Enum.filter(&is_step_node?/1)
      |> Enum.reject(fn n -> n["function"] in @synthetic_functions end)
      |> Enum.reduce(%{}, fn n, acc ->
        case function_spec(n["function"]) do
          %{scopes_required: scopes} when is_list(scopes) and scopes != [] ->
            slug = n["function"] |> String.split(".", parts: 2) |> List.first()
            Map.update(acc, slug, MapSet.new(scopes), fn s ->
              MapSet.union(s, MapSet.new(scopes))
            end)

          _ ->
            acc
        end
      end)

    missing_by_slug =
      Enum.reduce(requirements, %{}, fn {slug, required}, acc ->
        granted = granted_scopes_for(owner_id, slug)
        missing = MapSet.difference(required, granted) |> MapSet.to_list()
        if missing == [], do: acc, else: Map.put(acc, slug, missing)
      end)

    case map_size(missing_by_slug) do
      0 ->
        :ok

      _ ->
        details =
          Enum.map_join(missing_by_slug, "; ", fn {slug, missing} ->
            "`#{slug}` needs #{inspect(missing)}"
          end)

        {:error,
         "upsert_workflow: workflow needs OAuth scopes the user hasn't granted yet — #{details}. " <>
           "Tell the user to click **My Services → Reconnect** for each affected service so the " <>
           "next consent grants the missing scopes. The workflow will save once scopes are present."}
    end
  end

  defp check_scopes(_ir, _owner), do: :ok

  defp granted_scopes_for(owner_id, slug) when is_binary(slug) do
    # Credential targets are slug-keyed (`oauth:<slug>`) — see the
    # `finalize_oauth_service` / `finalize_connector_oauth` writers
    # in `Handlers.Data`. The catalog row is consulted only to
    # confirm the slug is a known service; `host_match` rides along
    # in the cred's payload but is no longer a primary key.
    case DmhAi.OAuth.Catalog.get_by_slug(slug) do
      %{} ->
        owner_id
        |> DmhAi.Auth.Credentials.lookup_all("oauth:" <> slug)
        |> Enum.flat_map(fn cred ->
          case Map.get(cred, :payload, %{}) do
            %{"scope" => s} when is_binary(s) -> String.split(s, " ", trim: true)
            %{"scopes" => list} when is_list(list) -> list
            _ -> []
          end
        end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # ─── deep validation: Mustache references resolve ──────────────────────
  #
  # The validator extracts every `{{ref}}` from any string in any
  # node's args, runs each through `Workflows.Path.parse/1`, and checks:
  #   - `:trigger` root — the leading path key is declared in the
  #     trigger node's `inputs[]` (or matches the leading segment of a
  #     dotted-name input like `deal.id`).
  #   - `{:node, n}` root — node id `n` exists AND its `emits` map
  #     declares the leading path key.
  #   - `:owner` / `:org` / `:now` / `:today` — built-in bindings; no
  #     further check.
  #
  # All ref discovery + parsing lives in `Workflows.Refs` /
  # `Workflows.Mustache` / `Workflows.Path` — single-pass state
  # machines, no regex. See `arch_wiki/dmh_ai/sme/layer-W.md`
  # §Mustache + Path grammar.

  alias DmhAi.Workflows.Refs

  defp check_references(_ir, nodes) do
    trigger_input_keys =
      nodes
      |> Enum.find(fn n -> n["kind"] == "trigger" end)
      |> case do
        nil -> []
        t   -> t |> Map.get("inputs", []) |> Enum.map(& &1["name"])
      end

    declared_ids   = nodes |> Enum.map(& &1["id"])
    declared_emits = collect_emits(nodes)

    nodes
    |> Enum.flat_map(fn node ->
      # Walk every value that may carry refs: `args` (step nodes),
      # `emit` (output nodes), and `cases[].when` (branch nodes).
      sources = [
        Map.get(node, "args", %{}),
        Map.get(node, "emit", %{}),
        Map.get(node, "cases", [])
      ]

      sources
      |> Enum.flat_map(&Refs.extract/1)
      |> Enum.map(&{node["id"], &1})
    end)
    |> Enum.reduce_while(:ok, fn {node_id, entry}, _acc ->
      case validate_ref(entry, trigger_input_keys, declared_ids, declared_emits) do
        :ok ->
          {:cont, :ok}

        {:error, why} ->
          {:halt,
           {:error,
            "upsert_workflow: node #{node_id} reference `{{#{Map.get(entry, :raw)}}}` — #{why}"}}
      end
    end)
  end

  # Known emit keys per node = explicit `emits` keys ∪ the keys the
  # function's manifest declares it `returns:`. Downstream refs may
  # bind against either — the explicit map (for aliased deep paths)
  # or the implicit set (for direct passthrough of the connector's
  # declared response shape). This makes the `emits` field optional
  # whenever the connector contract already names the field; the
  # model never repeats what the manifest already promises.
  defp collect_emits(nodes) do
    Enum.reduce(nodes, %{}, fn n, acc ->
      explicit =
        case Map.get(n, "emits") do
          e when is_map(e) -> Map.keys(e)
          _                -> []
        end

      implicit = function_returns_keys(Map.get(n, "function"))

      Map.put(acc, n["id"], Enum.uniq(explicit ++ implicit))
    end)
  end

  # Top-level keys the function's manifest declares it returns. nil /
  # missing → []. Used by `collect_emits/1` to credit downstream refs
  # against the manifest's declared `returns:` shape without the IR
  # having to repeat them in an `emits` map.
  defp function_returns_keys(nil), do: []
  defp function_returns_keys(fn_name) when is_binary(fn_name) do
    case function_spec(fn_name) do
      %{returns: r} when is_map(r) -> r |> Map.keys() |> Enum.map(&to_string/1)
      _ -> []
    end
  end
  defp function_returns_keys(_), do: []

  # Each entry from `Refs.extract/1` is either a parsed ref or a
  # parser error (carried through so we can surface a precise
  # diagnostic for the model).
  defp validate_ref(%{error: reason}, _t_keys, _ids, _emits),
    do: {:error, reason}

  defp validate_ref(%{parsed: %{root: :trigger, path: path}}, t_keys, _ids, _emits) do
    case path do
      [{:key, key} | _rest] ->
        if key in t_keys do
          :ok
        else
          # Allow trigger inputs declared with a leading dotted name
          # (e.g. `deal.id` — declared key is the WHOLE dotted string,
          # and a ref like `T.deal.id` walks past it as two segments).
          # Match against the leading segment OR the full declared
          # name's leading segment.
          if Enum.any?(t_keys, fn declared ->
               leading = declared |> String.split(".") |> List.first()
               leading == key
             end) do
            :ok
          else
            {:error, "no matching trigger input (declared: #{inspect(t_keys)})"}
          end
        end

      [] ->
        {:error, "trigger ref needs at least one path segment"}

      _ ->
        {:error, "trigger ref must start with a key segment"}
    end
  end

  defp validate_ref(%{parsed: %{root: {:node, n}, path: path}}, _t_keys, ids, emits) do
    cond do
      not Enum.member?(ids, n) ->
        {:error, "node id #{n} not declared"}

      path == [] ->
        {:error, "node reference needs at least one path segment after `#{n}.`"}

      true ->
        case path do
          [{:key, key} | _rest] ->
            if Enum.member?(Map.get(emits, n, []), key) do
              :ok
            else
              {:error, "node #{n} doesn't declare emit `#{key}` " <>
                "(check the function's manifest `returns:` for the available top-level keys; " <>
                "for nested fields, declare `emits: {#{key}: \"$.<jsonpath>\"}` on node #{n})"}
            end

          [{:index, _i} | _rest] ->
            # Index-first path against a node emit is unusual but not
            # nonsensical (e.g. when the emit is a top-level list).
            # The validator can't know the runtime shape, so allow it.
            :ok
        end
    end
  end

  # `:org` accepts org-level facts only (`{{org.name}}`, `{{org.id}}`).
  # The legacy `{{org.me.<x>}}` alias was an indirection for the
  # owner's record; it's been replaced by `{{owner.<x>}}` (DMH-AI app
  # identity) and `{{owner.<slug>.email}}` (per-connector vendor
  # identity). Reject the legacy form at compile time with explicit
  # remediation pointing at the current binding.
  defp validate_ref(%{parsed: %{root: :org, path: [{:key, "me"} | _]}},
                    _t_keys, _ids, _emits) do
    {:error,
     "`{{org.me.<x>}}` is not a valid binding. Use `{{owner.<x>}}` for the " <>
       "workflow owner's DMH-AI app identity (e.g. `{{owner.email}}`), or " <>
       "`{{owner.<slug>.email}}` for the owner's vendor identity captured " <>
       "at OAuth time (e.g. `{{owner.hubspot.email}}` for the HubSpot account " <>
       "email used to connect)."}
  end

  defp validate_ref(%{parsed: %{root: root}}, _t_keys, _ids, _emits)
       when root in [:owner, :org, :now, :today] do
    :ok
  end

  # `:local` roots are template-local placeholders — the synthetic
  # primitive (or whatever consumer) resolves them at run time. The
  # validator has nothing to check against; pass through.
  defp validate_ref(%{parsed: %{root: :local}}, _t_keys, _ids, _emits), do: :ok

  # Poll triggers MUST point at a connector function whose manifest
  # declares `poll_trigger_capable: true` (with the cursor protocol
  # fields). A workflow that names a non-pollable function as its poll
  # connector is broken at compile time — surface it now rather than
  # let the Poller fail at every tick.
  defp check_poll_trigger_manifest(nodes) do
    trigger = Enum.find(nodes, fn n -> n["kind"] == "trigger" end)

    case trigger do
      %{"trigger_kind" => "poll"} = t ->
        case Map.get(t, "connector_function") do
          nil ->
            {:error,
             "upsert_workflow: poll trigger (node #{t["id"]}) must declare `connector_function`"}

          fn_name when is_binary(fn_name) ->
            case poll_capable?(fn_name) do
              :ok ->
                :ok

              {:error, why} ->
                {:error,
                 "upsert_workflow: poll trigger node #{t["id"]} — `#{fn_name}` is not poll-trigger-capable: #{why}"}
            end
        end

      _ ->
        :ok
    end
  end

  # Cadence enforcement. Per layer-W.md §Cadence:
  #   - poll triggers must have every_seconds AND >= manifest.min_poll_seconds
  #   - schedule triggers must have every_seconds: positive int (v1; cron comes later)
  # Distinct error messages so the model knows which side it tripped.
  defp check_trigger_cadence(nodes) do
    trigger = Enum.find(nodes, fn n -> n["kind"] == "trigger" end)

    case trigger do
      %{"trigger_kind" => "poll"} = t ->
        validate_poll_cadence(t)

      %{"trigger_kind" => "schedule"} = t ->
        validate_schedule_cadence(t)

      _ ->
        :ok
    end
  end

  defp validate_poll_cadence(trigger) do
    every = Map.get(trigger, "every_seconds")
    fn_name = Map.get(trigger, "connector_function")

    floor = poll_floor_for(fn_name)
    default = poll_default_for(fn_name)

    cond do
      not is_integer(every) ->
        {:error,
         "upsert_workflow: poll trigger (node #{trigger["id"]}) must declare " <>
           "`every_seconds: <integer>`. Connector `#{fn_name}` recommends " <>
           "`#{default}` and requires at least `#{floor}`. " <>
           "Pick a cadence from the user's prose (\"real-time\" → floor; " <>
           "\"every few minutes\" → 300; \"hourly\" → 3600; no hint → recommended)."}

      every <= 0 ->
        {:error,
         "upsert_workflow: poll trigger `every_seconds` must be positive (got #{every})"}

      is_integer(floor) and every < floor ->
        {:error,
         "upsert_workflow: poll trigger `every_seconds=#{every}` is below the " <>
           "connector's floor for `#{fn_name}` (min_poll_seconds=#{floor}). " <>
           "Raise to at least #{floor}, or pick the recommended #{default}."}

      true ->
        :ok
    end
  end

  defp validate_schedule_cadence(trigger) do
    every = Map.get(trigger, "every_seconds")
    cron  = Map.get(trigger, "cron")

    cond do
      is_binary(cron) and cron != "" ->
        # v1 doesn't execute cron strings yet, but the IR can carry
        # them — the future cron evaluator will pick them up. For now
        # accept and move on.
        :ok

      is_integer(every) and every > 0 ->
        :ok

      true ->
        {:error,
         "upsert_workflow: schedule trigger (node #{trigger["id"]}) needs " <>
           "either `every_seconds: <positive integer>` (v1 cadence form) " <>
           "or `cron: \"<expression>\"` (v2; not yet executed but accepted). " <>
           "Pick one. If the user said \"daily\" use `86400`; \"every Monday\" " <>
           "use a cron expression."}
    end
  end

  defp poll_floor_for(fn_name),    do: poll_manifest_field(fn_name, :min_poll_seconds)
  defp poll_default_for(fn_name),  do: poll_manifest_field(fn_name, :default_poll_seconds)

  defp poll_manifest_field(nil, _key), do: nil
  defp poll_manifest_field(fn_name, key) when is_binary(fn_name) do
    case ConnectorManifest.lookup_fqn(fn_name) do
      %{} = spec -> Map.get(spec, key)
      nil        -> nil
    end
  end

  defp poll_capable?(fn_name) do
    case ConnectorManifest.lookup_fqn(fn_name) do
      nil ->
        {:error,
         "unknown function `#{fn_name}` — name must be `<slug>.<function>` and the " <>
           "connector must be configured + discovered"}

      %{poll_trigger_capable: true} ->
        :ok

      %{} ->
        {:error,
         "function `#{fn_name}` does not declare `poll_trigger_capable: true` " <>
           "(connector functions must declare cursor protocol in their manifest " <>
           "to be usable as a poll trigger — see layer-W.md §Cursor semantics)"}
    end
  end

  defp check_top_level_keys(ir) do
    # Trigger config used to be a top-level `trigger: {...}` field;
    # it's now a node with `kind: "trigger"` inside `nodes[]`. The
    # only required top-level field is `nodes`. `outputs[]` is
    # optional (a workflow can write its result via output-node
    # emits without an explicit outputs[] declaration).
    cond do
      not is_list(Map.get(ir, "nodes")) ->
        {:error, "upsert_workflow: ir.nodes missing or not an array"}

      is_list(Map.get(ir, "inputs")) ->
        {:error,
         "upsert_workflow: IR has a top-level `inputs` array. Trigger inputs " <>
           "belong on the TRIGGER node, not at the IR root. Move the array " <>
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
