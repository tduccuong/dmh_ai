# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.InvokeWorkflow do
  @moduledoc """
  Run a saved workflow once with caller-supplied inputs. Always
  fires the workflow's `current_version` (the latest saved shape) —
  there is no version arg. Non-latest versions are historical and
  not runnable.

  Distinct from `arm_workflow` — arming registers a trigger
  (schedule / poll / webhook) that fires the workflow autonomously.
  This tool fires a single one-off run with caller-supplied inputs,
  bypassing the trigger.

  Use cases:
  - User says *"run customer_onboarding_from_deal for deal-12345"* in chat.
  - User picks a workflow via the picker (inserts a `&<slug>` reference);
    the model translates the user's prose around it into an inputs
    map and calls this tool.
  - One workflow invokes another (`workflow.invoke` as a synthetic
    step in an IR).
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.{Workflows, Constants}
  alias DmhAi.Workflows.Executor
  require Logger

  @impl true
  def name, do: "invoke_workflow"

  @impl true
  def description do
    """
    Run a saved workflow once with supplied inputs. Args: name (slug), inputs (map matching the trigger's inputs). Always uses the workflow's latest saved version.

    Report the ACTUAL result, not optimism. `invoke_workflow` returns `{executor_status, run_id, run_url, workflow_url, emits, ...}`. After every invocation, your final reply MUST:
    1. State the `executor_status` verbatim ("Status: completed" / "Status: failed" / etc.). Do not paraphrase to "successful" if it isn't `"completed"`.
    2. Show the actual emit VALUES from the `emits` map (the executor's output, indexed by node_id). This is what the user came for — surface it inline, formatted as a short list or key/value pairs.
    3. Render the `run_url` (NOT `workflow_url`) as the primary markdown link. Format: `[<workflow display_name> run · <status>](<run_url>)`. The run viewer shows the actual output; the workflow viewer shows the static IR — they are different surfaces. `workflow_url` is a secondary link you may include only if the user explicitly asks to see the definition.
    4. If `executor_status == "completed"` but the emit map is empty or contains placeholder strings ("", null, "unknown", etc.) — say so honestly. Don't claim a successful outcome you can't see.

    Required-input validation: if `invoke_workflow` returns `"missing required trigger inputs … Declared schema: …"`, reply to the user with the missing field names, the schema, and one example of prose that would supply them. Wait for the user to clarify.

    Run failures end the chain. When `invoke_workflow` returns `executor_status: "failed"`, report the structured error to the user and wait. The IR is the operator's contract; only they decide how to reconcile a world that doesn't match it.
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
          name: %{
            type:        "string",
            description: "The workflow's slug."
          },
          inputs: %{
            type:        "object",
            description: "Values for the workflow's trigger inputs, e.g. {deal: {id: '12345', contact_email: 'x@y.com'}}."
          }
        },
        required: ["name", "inputs"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    org_id     = Map.get(ctx, :org_id) || Constants.default_org_id()
    user_id    = Map.get(ctx, :user_id)
    session_id = Map.get(ctx, :session_id)

    name_arg = args["name"]
    inputs   = args["inputs"]

    with :ok        <- require_string(name_arg, "name"),
         :ok        <- require_map(inputs, "inputs"),
         :ok        <- require_string(user_id, "ctx.user_id"),
         :ok        <- require_string(session_id, "ctx.session_id"),
         {:ok, wf}  <- fetch_workflow(org_id, name_arg),
         {:ok, ver} <- resolve_current_version(wf),
         {:ok, v}   <- fetch_version(org_id, name_arg, ver),
         :ok        <- require_manual_trigger(name_arg, v.ir),
         :ok        <- validate_trigger_inputs(name_arg, v.ir, inputs) do

      # Synthetic run label so the executor's run_state has a stable
      # `task_id` column entry for logs / dashboards. No bind to any
      # task table — workflow runs are tracked in `workflow_runs`.
      task_id = "invoke-#{System.os_time(:millisecond)}-#{:erlang.phash2({user_id, session_id, name_arg})}"

      Logger.info("[InvokeWorkflow] workflow=#{name_arg} v#{ver} session=#{session_id}")

      # The deterministic executor takes over. The LLM is no longer
      # in the workflow run loop (except for explicit llm.compose
      # steps). caller_ctx.user_id is the workflow's owner.
      exec_ctx = %{org_id: org_id, task_id: task_id}

      case Executor.start_run(name_arg, ver, inputs, exec_ctx) do
        {:ok, run_state} ->
          # The model must surface `run_url` (NOT workflow_url) so
          # the user sees the run's emit values, not the static IR.
          # `workflow_url` is provided as a secondary link for IR
          # inspection. See arch_wiki/dmh_ai/sme/layer-W.md.
          {:ok, %{
            "name"            => name_arg,
            "display_name"    => wf.display_name,
            "version"         => ver,
            "task_id"         => task_id,
            "run_id"          => run_state.id,
            "run_url"         => "/runs/#{run_state.id}",
            "workflow_url"    => "/workflows/#{URI.encode(name_arg)}/#{ver}",
            "executor_status" => run_state.status,
            "emits"           => Map.get(run_state.bindings, "emits", %{})
          }}

        {:error, reason} ->
          {:error, "invoke_workflow: executor failed: #{inspect(reason)}"}
      end
    end
  end

  # A manual invocation only makes sense for `trigger_kind: manual`.
  # For poll / schedule / webhook, "running it once" would either lie
  # about its data (no real trigger event happened) or interfere with
  # the autonomous loop's cursor. Refuse with a structured envelope so
  # the model relays it cleanly to the user.
  defp require_manual_trigger(name, ir) do
    case trigger_kind(ir) do
      "manual" ->
        :ok

      other ->
        connector =
          ir
          |> trigger_node()
          |> case do
            nil -> nil
            t   -> Map.get(t, "connector_function") || Map.get(t, "event")
          end

        {:error,
         "invoke_workflow: workflow `#{name}` has trigger_kind=`#{other}`; " <>
           "manual one-off runs are only allowed on `manual` triggers. " <>
           "To exercise this workflow, either:\n" <>
           " (a) cause the real trigger event (for `#{other}` + " <>
           "`#{connector || "—"}` this means causing the connector to fire — " <>
           "the model should suggest a concrete way based on the connector); or\n" <>
           " (b) arm the autonomous trigger via `arm_workflow` so it starts " <>
           "firing on its own.\n\n" <>
           "Reply to the user with these two options in their language. " <>
           "Do NOT retry `invoke_workflow` on this workflow."}
    end
  end

  defp trigger_node(ir) do
    ir |> Map.get("nodes", []) |> Enum.find(fn n -> n["kind"] == "trigger" end)
  end

  defp trigger_kind(ir) do
    case trigger_node(ir) do
      nil -> "manual"
      t   -> Map.get(t, "trigger_kind", "manual")
    end
  end

  # Required-input check. Trigger declared inputs are treated as
  # required by default — if a workflow needs an optional input,
  # the IR should mark it explicitly (future extension). For now
  # every declared input MUST appear in the supplied `inputs` map
  # for the run to start.
  defp validate_trigger_inputs(name, ir, inputs) do
    declared =
      ir
      |> Map.get("nodes", [])
      |> Enum.find(fn n -> n["kind"] == "trigger" end)
      |> case do
        nil -> []
        t   -> Map.get(t, "inputs", [])
      end

    declared_names =
      declared
      |> Enum.flat_map(fn
        %{"name" => n} when is_binary(n) and n != "" -> [n]
        _                                            -> []
      end)

    # Each declared `name` may be a dotted path (e.g. `"deal.id"`).
    # Matching against a supplied inputs map allows either:
    #   1. an exact top-level key `"deal.id"`
    #   2. a nested resolution `inputs["deal"]["id"]`
    # Both are valid because the executor flattens via Mustache
    # at run-time. We accept the simpler case (top-level only)
    # plus the explicit nested form.
    missing =
      Enum.reject(declared_names, fn n ->
        Map.has_key?(inputs, n) or nested_present?(inputs, n)
      end)

    case missing do
      [] ->
        :ok

      fields ->
        schema_json = Jason.encode!(declared)
        supplied    = inputs |> Map.keys() |> Jason.encode!()

        {:error,
         "invoke_workflow: missing required trigger inputs for `#{name}`: " <>
           "#{Enum.join(fields, ", ")}. " <>
           "Declared schema: #{schema_json}. Supplied keys: #{supplied}. " <>
           "Push back to the user with: (a) the names of the missing fields, " <>
           "(b) the full schema (types + names), (c) a brief example of " <>
           "prose that WOULD work for this workflow. Do NOT invent values."}
    end
  end

  defp nested_present?(inputs, dotted) when is_binary(dotted) do
    dotted
    |> String.split(".")
    |> Enum.reduce_while({:ok, inputs}, fn key, {:ok, acc} ->
      case acc do
        m when is_map(m) ->
          case Map.fetch(m, key) do
            {:ok, v} -> {:cont, {:ok, v}}
            :error   -> {:halt, :missing}
          end

        _ -> {:halt, :missing}
      end
    end)
    |> case do
      {:ok, _} -> true
      _        -> false
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  defp require_string(v, _label) when is_binary(v) and v != "", do: :ok
  defp require_string(_, label),
    do: {:error, "invoke_workflow: missing #{label}"}

  defp require_map(v, _label) when is_map(v), do: :ok
  defp require_map(_, label),
    do: {:error, "invoke_workflow: `#{label}` must be a JSON object"}

  defp fetch_workflow(org_id, name) do
    case Workflows.get_workflow(org_id, name) do
      nil -> {:error, "invoke_workflow: no workflow `#{name}` in this org"}
      wf  -> {:ok, wf}
    end
  end

  # Only `current_version` is runnable — non-latest versions are
  # historical. See layer-W.md §Latest-version-only runnability.
  defp resolve_current_version(%{current_version: cv}) when is_integer(cv) and cv >= 0,
    do: {:ok, cv}
  defp resolve_current_version(_),
    do: {:error, "invoke_workflow: workflow has no saved versions"}

  defp fetch_version(org_id, name, v) do
    case Workflows.get_version(org_id, name, v) do
      nil -> {:error, "invoke_workflow: workflow `#{name}` has no version #{v}"}
      ver -> {:ok, ver}
    end
  end
end
