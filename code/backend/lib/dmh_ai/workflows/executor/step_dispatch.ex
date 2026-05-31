# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.StepDispatch do
  @moduledoc """
  Step-call dispatch. Routes a resolved `(function, args, node, state)`
  tuple to either:

    * a runtime synthetic (`llm.compose`, `llm.summarise`,
      `builtin.coalesce`) the executor handles inline — the catalog
      refuses dispatch (G5 carve-out), so the executor owns these;
    * the connector catalog (`DmhAi.Tools.Catalog.call/3`) for every
      vendor tool.

  Owns the synthetic implementations + `render_template/2` (Mustache
  substitution for `llm.compose`).
  """

  alias DmhAi.Tools.Catalog

  @synthetic_names ~w(llm.compose llm.summarise builtin.coalesce)

  @doc """
  Dispatch a resolved step. Synthetic names short-circuit into the
  runtime implementations; everything else hands off to the connector
  catalog with the per-step `ctx` (owner / act-as / org / step_seq).
  """
  def dispatch_step(fn_name, args, _node, state) when fn_name in @synthetic_names do
    run_llm_synthetic(fn_name, args, state)
  end

  def dispatch_step(fn_name, args, node, state) do
    ctx = %{
      user_id:        state.owner_user_id,
      act_as_user_id: node["act_as_user_id"],
      task_id:        state.task_id,
      org_id:         state.org_id,
      step_seq:       node["id"]
    }

    Catalog.call(fn_name, args, ctx)
  end

  # The executor invokes the LLM directly for synthetics — the
  # Catalog refuses dispatch (G5 carve-out). Compose-only role; one
  # structured reply expected to match the manifest's emits_schema.
  defp run_llm_synthetic("llm.compose", args, _state) do
    template = Map.get(args, "template") || Map.get(args, :template) || ""
    context  = Map.get(args, "context")  || Map.get(args, :context)  || %{}

    # v1 implementation: render via Mustache substitution on the
    # template using the context map. Future: swap in a Swift LLM
    # call when the template alone isn't enough.
    rendered = render_template(template, context)
    {:ok, %{"subject" => "", "body" => rendered, "rendered" => rendered}}
  end

  defp run_llm_synthetic("llm.summarise", args, _state) do
    text = Map.get(args, "text") || Map.get(args, :text) || ""
    {:ok, %{"summary" => String.slice(text, 0, 400)}}
  end

  # `builtin.coalesce` — null-coalescing primitive for the join /
  # merge problem. Branches that converge on a downstream step's
  # arg (typical pattern: `contact.find` succeeds OR `contact.create`
  # runs as a fallback; downstream `deal.create` needs ONE contact_id
  # regardless of which path ran) put a `coalesce` step at the join
  # point. Its `values:` arg is an ordered list; the executor picks
  # the first non-nil value and emits it as `value`.
  #
  #   - id: 4
  #     kind: step
  #     function: builtin.coalesce
  #     args:
  #       values:
  #         - "{{1.contact_id}}"   # from contact.find (the happy path)
  #         - "{{3.contact_id}}"   # from contact.create (the fallback)
  #     emits: { value: $.value }
  #     next: 5
  #   - id: 5
  #     kind: step
  #     function: hubspot.deal.create
  #     args:
  #       contact_id: "{{4.value}}"
  #       …
  #
  # The args are resolved by the executor's normal binding pass
  # before this synthetic runs; we see the already-substituted
  # values (nil for branches that didn't execute).
  defp run_llm_synthetic("builtin.coalesce", args, _state) do
    values = Map.get(args, "values") || Map.get(args, :values) || []

    picked =
      values
      |> List.wrap()
      |> Enum.find(fn v -> not is_nil(v) and v != "" end)

    {:ok, %{"value" => picked}}
  end

  defp render_template(template, context) when is_binary(template) and is_map(context) do
    Regex.replace(~r/\{\{([^}]+)\}\}/, template, fn _full, key ->
      key = String.trim(key)
      val = Map.get(context, key) || Map.get(context, String.to_atom(key)) || ""
      to_string(val)
    end)
  end

  defp render_template(_, _), do: ""
end
