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

  This module is a thin shell over the validator passes that live
  under `__MODULE__.{Normalise, Shape, Functions, RequiredArgs,
  Provenance, BranchPredicates, Scopes, References, Triggers,
  Permissions}`. The Tool behaviour callbacks
  (`name/0`/`catalog_manifest/0`/`description/0`/`definition/0`/
  `execute/2`) stay here so the dispatcher + tests continue to
  resolve them on `DmhAi.Tools.UpsertWorkflow`.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.{Constants, Workflows}

  alias __MODULE__.{
    BranchPredicates,
    Functions,
    Normalise,
    Permissions,
    Provenance,
    References,
    RequiredArgs,
    Scopes,
    Shape,
    Triggers
  }

  require Logger

  @impl true
  def name, do: "upsert_workflow"

  @impl true
  def catalog_manifest, do: %{write_class: :write}

  @impl true
  def description do
    """
    Save a compiled workflow as a new version under the current org. Bumps the version on every save; first save lands at v0. Returns `{name, version, url, display_name}` — render `[<display_name> · v<version>](<url>)` as a markdown link in the chat reply (the URL is a relative path the FE viewer intercepts; never prefix a hostname).

    Trigger this tool when the user describes a repeatable AUTOMATION ("every Monday do X", "when a deal closes do Y", "build me a workflow that …"). Compile the prose into the IR and persist.

    Each connector tool's contract is already in its tool definition — arg types + `required` in `parameters`, plus a `Contract —` line giving per-arg provenance, the return-key shape, and OAuth scopes. Read it there; don't probe. Only for vendor-managed enums whose values depend on THIS user's account (stage/calendar ids, label names) call `inspect_function_property(name, path)` for the live values; trust the literal on `source: "not_supported"`.

    IR shape (the only required top-level key is `nodes`; `outputs` is optional; `inputs` lives on the trigger node — never at the root):

    ```
    trigger:  { id, kind:"trigger", label, trigger_kind, inputs:[], next, …kind-specific }
                trigger_kind ∈ manual | schedule | poll | webhook
                schedule + every_seconds   poll + every_seconds, connector_function, connector_args, filter
                webhook  + event, match    manual has no extras
    step:     { id, kind:"step", label, function:"<slug>.<fn>"|"<synthetic>", args:{…}, next }
    branch:   { id, kind:"branch", label, cases:[{when, next}], else:{next} }
    gate:     { id, kind:"gate", label, approver:{role}, on_approve, on_reject }   # suspends for human approval
    wait:     { id, kind:"wait", label, trigger:{kind, event, match}, timeout_seconds, on_fire, on_timeout }
    output:   { id, kind:"output", label, emit:{<name>: <literal|{{binding}}>} }   # terminal, no function/args
    ```

    Minimal shape — every IR opens with exactly one `kind:"trigger"` node; node ids are INTEGERS; `next` chains them; a step binds to a prior node by its integer id (`{{1.<field>}}`):

    ```
    nodes:
      - { id: 0, kind: trigger, trigger_kind: manual, inputs: [], next: 1 }
      - { id: 1, kind: step,    function: "<slug>.<fn>", args: { … }, next: 2 }
      - { id: 2, kind: output,  emit: { result: "{{1.<field>}}" } }
    ```

    Valid `function:` values are EXACTLY: (1) the `<slug>.<tool>` connector tools in your CURRENT tool defs — match each step to one that's actually listed; no match → the capability is absent, follow `<tool_catalog_contract>`. (2) These runtime synthetics (the executor resolves them; they never appear in your tool defs — use the names + shapes verbatim, don't invent variants):
    - `llm.compose(template, context)` → `{subject, body, rendered}` — fill text from a template + a context map of bindings.
    - `llm.summarise(text, max_words?)` → `{summary}` — compress a string.
    - `builtin.coalesce(values)` → `{value}` — first non-nil; the branch-convergence join.
    - `workflow.invoke(name, inputs)` → runs another saved workflow.

    Mustache binding grammar (the only forms the runtime resolves):
    - `{{T.<path>}}` — trigger input declared in the trigger node's `inputs[]`.
    - `{{<id>.<field>}}` — emit from a prior node id; `<field>` is a key the function's manifest declares in `returns:` (or an alias you defined via `emits: {<short>: "$.<jsonpath>"}` on that node).
    - `{{now}}` / `{{today}}` — current UTC datetime / date. Append an offset for relative ranges: `{{now-<N><unit>}}` / `{{today-<N><unit>}}`, sign `+` or `-`, units `m`/`h`/`d`/`w` (minutes/hours/days/weeks). For a window that ends now and starts one period earlier, set its start to `{{now-<N><unit>}}`. No other arithmetic exists.
    - `{{owner.email}}` / `{{owner.<slug>.email}}` / `{{org.name}}` — `owner.email` is the app identity; `owner.<slug>.email` the per-connector vendor identity captured at OAuth time.

    Branch `cases[].when` is a single comparison `<operand> <op> <operand>`, `<op> ∈ {==,!=,<,>,<=,>=}`, operands are bindings / quoted strings / numbers / booleans / `null`. Express English predicates as comparisons ("nothing found" → `{{1.items[0]}} == null`). Convergence: when arms write the same field, join via `builtin.coalesce(values:[…])` and bind downstream to `{{<coalesce-id>.value}}`.

    Trigger-kind: ONE INSTANCE PER EVENT or PER TIME? Time-phrased ("every morning", "weekly") → `schedule`. Event-phrased ("when a new <thing> arrives") → `poll`. Both present ("every Monday, over last week's closed deals") → `schedule`; the "new/since" phrase lives in the STEPS, not the trigger. `webhook` only when the connector supports it and latency must be immediate.

    Cadence: every poll/schedule needs `every_seconds`. Poll: at or above the function's `min_poll_seconds` (the validator names the floor). Map "real-time" → floor, "every few minutes" → 300, "hourly" → 3600, no hint → the manifest's `default_poll_seconds`.

    Self-sufficiency: every required arg must trace to a trigger input, a prior emit, a built-in, the manifest's default, or a literal the user stated. Missing source → ask via `request_input` (the answer becomes a literal in the IR or a new trigger input); never fill a gap with placeholders like `"TBD"`/`"<x>"` — the validator rejects them. The save also fails when the workflow needs OAuth scopes the user hasn't granted — the error names the slug to reconnect.

    `node.label` is a full English rephrasing of the call that keeps every meaningful argument value (paraphrase mustache refs as "from step 2" / "from the trigger", never drop them). The viewer's Label tab is the non-technical reading surface.

    Per-version: every save bumps the version; only the latest is runnable (`invoke_workflow` / `arm_workflow` take no version arg). Refinement turn → save again → reply with the new link. `invoke_workflow(name, inputs)` is the one-off run for `trigger_kind: manual`; for poll/schedule/webhook triggers "run it" is ambiguous — ask whether to run once now (`invoke_workflow`) or arm the autonomous trigger (`arm_workflow`).

    `&<slug>` from the user loads a `<workflow_references>` block (the workflow's authoritative metadata + trigger_inputs schema) — route via `read_workflow` / `invoke_workflow` / `arm_workflow` / `upsert_workflow`. Workflows surfaced in `<augmented_facts type="indexed">` under the `workflow` class: when one matches the user's intent, offer to run or refine it rather than silently recreate.

    The validator returns precise errors (`unknown_function`, `missing_required_args`, `unbound_reference`, branch-predicate parse errors with examples, scope errors naming the slug). Read the error, fix the IR, retry — the message is the teacher.
    """
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

    with :ok                 <- Normalise.require_string(user_id, "ctx.user_id"),
         :ok                 <- Normalise.require_string(session_id, "ctx.session_id"),
         {:ok, display_name} <- Normalise.normalise_display_name(args["display_name"]),
         {:ok, slug}         <- Normalise.normalise_slug(args["name"], display_name),
         {:ok, description}  <- Normalise.normalise_description(args["description"]),
         {:ok, ir}           <- Normalise.normalise_ir(args["ir"]),
         {:ok, change_note}  <- Normalise.normalise_change_note(args["change_note"]),
         {:ok, nodes}        <- Shape.shape_validate(ir),
         :ok                 <- Functions.check_functions_exist(nodes),
         :ok                 <- Triggers.check_poll_trigger_manifest(nodes),
         :ok                 <- Triggers.check_trigger_cadence(nodes),
         :ok                 <- RequiredArgs.check_required_args(nodes),
         :ok                 <- References.check_references(ir, nodes),
         :ok                 <- Provenance.check_arg_provenance(nodes),
         :ok                 <- BranchPredicates.check_branch_predicates(nodes),
         {:ok, owner_id}     <- Permissions.resolve_owner(org_id, slug, user_id),
         :ok                 <- Permissions.check_permissions(ir, owner_id),
         :ok                 <- Scopes.check_scopes(ir, owner_id) do

      params = %{
        org_id:       org_id,
        id:           slug,
        display_name: display_name,
        description:  description,
        ir:           ir,
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
end
