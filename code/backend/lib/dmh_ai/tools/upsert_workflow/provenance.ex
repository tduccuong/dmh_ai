# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.Provenance do
  @moduledoc """
  L1 — Arg-provenance enforcement. See
  `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency / L1.
  Each connector function's manifest may annotate required args
  with a `provenance:` clause stating WHERE the value must come
  from at IR write time. The validator enforces that clause — the
  runtime can then rely on every required value tracing to a known
  source instead of relying on regex heuristics to spot
  placeholders.

  Provenance kinds:
    * `:from_user`       — value MUST be `{{T.<x>}}` (trigger input).
      Literals forbidden; the user supplies the value at invoke time.
    * `:lookup`          — value MUST be `{{<N>.<field>}}` (an
      upstream step's emit). Trigger inputs forbidden because the
      user typically doesn't know vendor-internal ids.
    * `:built_in`        — value MUST equal the named built-in binding.
    * `:literal_default` — literals are acceptable (the connector
      author has decided this arg is configuration the workflow
      author legitimately bakes in).

  Default when no annotation: `:literal_default` (permissive).
  Connector authors opt INTO strict enforcement by annotating
  per arg.
  """

  alias DmhAi.Tools.UpsertWorkflow.{Functions, RequiredArgs, Synthetics}

  @doc """
  Reject step nodes whose required-arg values violate their
  manifest's declared provenance clause.
  """
  @spec check_arg_provenance([map()]) :: :ok | {:error, String.t()}
  def check_arg_provenance(nodes) do
    nodes
    |> Enum.filter(&Functions.is_step_node?/1)
    |> Enum.reject(fn n -> n["function"] in Synthetics.list() end)
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

  @doc """
  Scan a single step node — find the first required arg whose
  value fails its declared provenance, or `:ok` if all pass.
  """
  @spec scan_node_provenance(map()) :: :ok | {:provenance_error, any(), map(), any()}
  def scan_node_provenance(node) do
    case RequiredArgs.function_spec(node["function"]) do
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

  @doc """
  Per-kind provenance validation. `:ok` if the value satisfies the
  declared provenance kind; `:error` otherwise (the caller wraps it
  into a teaching error with `provenance_advice/1`).
  """
  @spec validate_value_provenance(any(), map()) :: :ok | :error
  # Permissive default — literals + bindings all pass. The connector
  # author opted not to constrain this arg.
  def validate_value_provenance(_value, %{kind: :literal_default}), do: :ok
  def validate_value_provenance(_value, %{kind: kind}) when kind == nil, do: :ok

  # `:from_user` — value MUST be a `{{T.<x>}}` trigger-input binding.
  # Literals are forbidden because they freeze the workflow at one
  # invented value; the user should supply this at each invocation.
  def validate_value_provenance(value, %{kind: :from_user}) when is_binary(value) do
    if String.starts_with?(value, "{{T.") and String.ends_with?(value, "}}"),
      do: :ok,
      else: :error
  end

  def validate_value_provenance(_value, %{kind: :from_user}), do: :error

  # `:lookup` — value MUST come from an upstream emit (`{{<N>.<field>}}`).
  # Trigger inputs are forbidden because the user typically doesn't know
  # vendor-internal ids (HubSpot's `contact_id`, Outlook's `event_id`);
  # they know emails, names, URLs. Forcing the upstream-step path means
  # the workflow ALWAYS resolves ids from human-friendly input via the
  # declared `source` finder verb. The upstream step's own provenance is
  # enforced recursively when we visit that node.
  def validate_value_provenance(value, %{kind: :lookup}) when is_binary(value) do
    if String.match?(value, ~r/^\{\{\d+\..+\}\}$/), do: :ok, else: :error
  end

  def validate_value_provenance(_value, %{kind: :lookup}), do: :error

  # `:built_in` — value MUST equal the named binding.
  def validate_value_provenance(value, %{kind: :built_in, binding: binding}),
    do: if(value == binding, do: :ok, else: :error)

  def validate_value_provenance(_value, _), do: :ok

  @doc """
  Per-kind teaching advice the validator appends to a provenance
  rejection so the model knows what shape to write instead.
  """
  @spec provenance_advice(map()) :: String.t()
  def provenance_advice(%{kind: :from_user}),
    do: "This arg holds user-supplied data — declare a matching trigger input " <>
        "(`inputs: [{name: \"<arg>\", type: ...}]`) on the trigger node and bind " <>
        "the step's arg to `{{T.<arg>}}`. The user supplies the value at each " <>
        "invocation. If the value is genuinely fixed for every run, ask the user " <>
        "whether to bake it as a literal — and tell the connector author to annotate " <>
        "the arg as `provenance: %{kind: :literal_default}`."

  def provenance_advice(%{kind: :lookup, source: source}),
    do: "This arg is the id of a vendor object the user doesn't know directly. " <>
        "Add an upstream step calling `#{source}` (driven by a human-friendly " <>
        "input like email/name/URL via its `query` arg) and bind this arg to " <>
        "`{{<that_node_id>.<field>}}`. A trigger input `{{T.<x>}}` is NOT a " <>
        "valid shortcut — the user typically doesn't know vendor-internal ids."

  def provenance_advice(%{kind: :lookup}),
    do: "This arg must come from an upstream step's emit (`{{<N>.<field>}}`), " <>
        "not from a trigger input or a literal — the user doesn't know vendor " <>
        "ids directly."

  def provenance_advice(%{kind: :built_in, binding: binding}),
    do: "This arg must be the built-in binding `#{binding}`."

  def provenance_advice(_),
    do: "Pick a binding that matches the arg's declared provenance."
end
