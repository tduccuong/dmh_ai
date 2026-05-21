# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.InspectFunction do
  @moduledoc """
  Compile-time introspection for connector functions. The Assistant
  LLM calls this BEFORE writing each `step` node into a workflow IR
  so it sees the function's full contract — args (with type +
  required + provenance), declared return shape, declared error
  classes, and the OAuth scopes it needs. Without this the compiler
  has only the flat `tools/list` description and ends up inventing
  placeholder values for required args it doesn't know how to source.

  The tool is read-only and runs entirely off the in-process
  connector manifests; no vendor traffic.

  See `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency / L1.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Connectors.Registry, as: ConnectorRegistry

  @impl true
  def name, do: "inspect_function"

  @impl true
  def description do
    "Look up a connector function's full contract before writing it into a workflow IR. " <>
      "Returns the args (each with type, required, optional provenance telling you how to " <>
      "source the value), the declared return shape, the error classes the function can " <>
      "produce, and the OAuth scopes required. Call this BEFORE every step you compile — " <>
      "without it you don't know how to obtain required values (lookup vs trigger input vs " <>
      "literal) and you risk inventing placeholders the runtime can't recover from."
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
            type: "string",
            description:
              "Fully-qualified function name: `<slug>.<function>` (e.g. `hubspot.deal.create`, " <>
                "`google_workspace.gmail.search`). The slug is the connector's slug from " <>
                "`<authorized_services>`; the function name is what appears in `tools/list` " <>
                "after attach."
          }
        },
        required: ["name"]
      }
    }
  end

  @impl true
  def execute(%{"name" => fn_name}, _ctx) when is_binary(fn_name) do
    with [slug, bare] <- String.split(fn_name, ".", parts: 2),
         mod when not is_nil(mod) <- ConnectorRegistry.module_for_slug(slug),
         manifest <- safe_manifest(mod),
         %{} = spec <- Map.get(Map.get(manifest, :functions, %{}), bare) do
      {:ok, format(slug, bare, spec)}
    else
      _ ->
        {:error,
         "inspect_function: no function named `#{fn_name}` — name must be `<slug>.<function>` " <>
           "and the connector must be registered. See `<authorized_services>` for valid slugs " <>
           "and call `connect_mcp` first to discover function names."}
    end
  end

  def execute(_, _),
    do: {:error, "inspect_function: missing required arg `name` (string)"}

  # ─── private ─────────────────────────────────────────────────────────

  defp safe_manifest(mod) do
    if function_exported?(mod, :manifest, 0), do: mod.manifest(), else: %{functions: %{}}
  end

  defp format(slug, bare, spec) do
    %{
      "name"             => "#{slug}.#{bare}",
      "kind"             => kind_for(spec),
      "permission"       => to_string(Map.get(spec, :permission, :read)),
      "args"             => format_args(Map.get(spec, :args, %{})),
      "returns"          => format_returns(Map.get(spec, :returns, %{})),
      "error_classes"    => format_atoms(Map.get(spec, :errors, [])),
      "scopes_required"  => Map.get(spec, :scopes, []),
      "idempotency_key"  => to_string(Map.get(spec, :idempotency_key, :none))
    }
  end

  defp kind_for(spec) do
    case Map.get(spec, :permission) do
      :read  -> "read"
      :write -> "write"
      :admin -> "admin"
      _      -> "read"
    end
  end

  defp format_args(args) when is_map(args) do
    Enum.into(args, %{}, fn {name, meta} ->
      out =
        meta
        |> Map.take([:type, :required, :format, :enum, :pattern, :description, :provenance])
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Enum.into(%{}, fn
          {:type, t}        -> {"type",        to_string(t)}
          {:required, r}    -> {"required",    r}
          {:format, f}      -> {"format",      to_string(f)}
          {:enum, e}        -> {"enum",        e}
          {:pattern, p}     -> {"pattern",     p}
          {:description, d} -> {"description", d}
          {:provenance, p}  -> {"provenance",  format_provenance(p)}
        end)

      {to_string(name), Map.put_new(out, "required", false)}
    end)
  end

  defp format_args(_), do: %{}

  defp format_returns(returns) when is_map(returns) do
    Enum.into(returns, %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp format_returns(_), do: %{}

  defp format_atoms(list) when is_list(list),
    do: Enum.map(list, &to_string/1)

  defp format_atoms(_), do: []

  # `provenance` (optional per arg) is a small declarative shape the
  # compiler reads to decide HOW to source the value:
  #
  #   {kind: "from_user"}                            — bind to trigger input / user prose
  #   {kind: "lookup", source: "<fn>", result_field: "<f>"}
  #                                                   — add an upstream step calling <source>
  #   {kind: "built_in", binding: "{{org.me.email}}"} — use the named built-in
  #   {kind: "vendor_enum", enumerate: "<fn>"}        — value is a vendor enum; call <fn> to list
  #   {kind: "literal_default", value: <v>}           — connector ships a default
  #
  # Connectors that don't supply `provenance` for an arg leave it
  # unset; the compiler treats unset as the conservative
  # `{kind: "from_user"}` (must be explicitly bound).
  defp format_provenance(%{kind: kind} = p) do
    base = %{"kind" => to_string(kind)}

    Enum.reduce(p, base, fn
      {:kind, _}, acc -> acc
      {k, v}, acc when is_atom(v) -> Map.put(acc, to_string(k), to_string(v))
      {k, v}, acc -> Map.put(acc, to_string(k), v)
    end)
  end

  defp format_provenance(other) when is_map(other), do: other
  defp format_provenance(_), do: %{"kind" => "from_user"}
end
