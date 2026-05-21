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
         :ok            <- check_placeholder_args(nodes) do
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

  # ─── L5 — Placeholder soundness backstop ──────────────────────────────
  #
  # See `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency / L5.
  # The compiler must never let the model save an IR whose required args
  # carry placeholder-shaped literals — armed workflows fire without an
  # LLM around to recover from a vendor rejection rooted in an invented
  # value.

  @placeholder_tokens ~w(unknown todo placeholder foo bar example test xxx none)
  @quantity_arg_pattern ~r/amount|price|quantity|count|limit|max_/

  defp check_placeholder_args(nodes) do
    nodes
    |> Enum.filter(&is_step_node?/1)
    |> Enum.reject(fn n -> n["function"] in @synthetic_functions end)
    |> Enum.reduce_while(:ok, fn node, _acc ->
      case scan_node_for_placeholders(node) do
        :ok ->
          {:cont, :ok}

        {:placeholder, arg, value} ->
          {:halt,
           {:error,
            "upsert_workflow: node #{node["id"]} (`#{node["function"]}`) required arg " <>
              "`#{arg}` has a placeholder-shaped value #{inspect(value)}. " <>
              "Workflows run autonomously — every required value must trace to a trigger " <>
              "input (`{{T.<name>}}`), a prior step's emit (`{{N.<field>}}`), a built-in " <>
              "(`{{org.*}}`, `{{now}}`), or a literal the user explicitly stated. " <>
              "Either declare a trigger input the user supplies at invoke time, add an " <>
              "upstream lookup step that emits the value, or ask the user before saving."}}
      end
    end)
  end

  defp scan_node_for_placeholders(node) do
    case function_spec(node["function"]) do
      %{args: arg_schema} ->
        required =
          arg_schema
          |> Enum.filter(fn {_k, v} -> Map.get(v, :required) == true end)
          |> Enum.map(fn {k, _v} -> to_string(k) end)

        args = Map.get(node, "args", %{})

        Enum.find_value(required, :ok, fn arg ->
          value = Map.get(args, arg)

          if looks_like_placeholder?(arg, value),
            do: {:placeholder, arg, value},
            else: nil
        end)
        |> case do
          {:placeholder, _, _} = hit -> hit
          _                          -> :ok
        end

      _ ->
        :ok
    end
  end

  # A value is a "placeholder" only if it's a literal (not a `{{...}}`
  # binding) AND matches one of the shapes we know the model invents
  # when it has no real source for a required arg. Bindings to trigger
  # inputs / prior emits / built-ins always pass; the runtime resolves
  # them deterministically.
  defp looks_like_placeholder?(_arg, value) when is_binary(value) do
    cond do
      String.starts_with?(value, "{{") -> false   # binding
      value == ""                       -> true
      String.length(value) == 1         -> true   # "1", "x"
      String.downcase(value) in @placeholder_tokens -> true
      true                              -> false
    end
  end

  defp looks_like_placeholder?(arg, 0) do
    String.match?(arg, @quantity_arg_pattern)
  end

  defp looks_like_placeholder?(_arg, nil), do: true

  defp looks_like_placeholder?(_arg, _v), do: false

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
          %{scopes: scopes} when is_list(scopes) and scopes != [] ->
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
    case DmhAi.OAuth.Catalog.get_by_slug(slug) do
      %{host_match: host} ->
        owner_id
        |> DmhAi.Auth.Credentials.lookup_all("oauth:" <> host)
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
    case String.split(fn_name, ".", parts: 2) do
      [slug, bare] ->
        case ConnectorRegistry.module_for_slug(slug) do
          nil -> nil
          mod ->
            try do
              spec = Map.get(mod.manifest().functions, bare)
              spec && Map.get(spec, key)
            rescue
              _ -> nil
            end
        end

      _ ->
        nil
    end
  end

  defp poll_capable?(fn_name) do
    case String.split(fn_name, ".", parts: 2) do
      [slug, bare] ->
        case ConnectorRegistry.module_for_slug(slug) do
          nil ->
            {:error, "unknown connector slug `#{slug}`"}

          mod ->
            try do
              spec = Map.get(mod.manifest().functions, bare)

              cond do
                is_nil(spec) ->
                  {:error, "unknown function `#{fn_name}`"}

                not Map.get(spec, :poll_trigger_capable, false) ->
                  {:error,
                   "function `#{fn_name}` does not declare `poll_trigger_capable: true` " <>
                     "(connector functions must declare cursor protocol in their manifest " <>
                     "to be usable as a poll trigger — see layer-W.md §Cursor semantics)"}

                true ->
                  :ok
              end
            rescue
              e -> {:error, "manifest lookup raised: #{Exception.message(e)}"}
            end
        end

      _ ->
        {:error, "function name must be namespaced (`<slug>.<fn>`)"}
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
