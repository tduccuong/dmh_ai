# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.InspectFunctionProperty do
  @moduledoc """
  Compile-time *deep* property introspection (Layer W L2). The
  compiler uses `inspect_function` (L1) to see a function's args;
  this tool drills further into args whose values are vendor-specific
  enums or vendor-managed objects whose schema can only be answered
  by the vendor itself for THIS user's account.

  Example shape of the situation: the user says *"create a HubSpot
  deal at the Qualified stage"*. The compiler needs to know:
  (a) is `Qualified` a real stage in this user's pipeline, and
  (b) what's the stage's vendor-side identifier? Both questions
  belong to vendor metadata, not the static connector manifest.

  The tool dispatches to the connector module's optional
  `inspect_property/3` callback. Connectors that don't implement it
  return `{:error, :not_supported}` — the compiler treats that as
  "trust the literal" and proceeds. Implementations that DO wire
  it return a schema fragment carrying type / enum / description /
  source (`:manifest` vs `:vendor_metadata`).

  See `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency / L2.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Connectors.Registry, as: ConnectorRegistry
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @impl true
  def name, do: "inspect_function_property"

  @impl true
  def description do
    "Drill into one property of a connector function's args — useful when the property is " <>
      "an open-ended vendor enum (deal stage, pipeline id, calendar id, mailbox label) " <>
      "whose valid values come from the user's vendor account, not the static manifest. " <>
      "Returns type + enum + description + source (`manifest` vs `vendor_metadata`). " <>
      "Call this BEFORE writing a literal value for any property whose enum you don't " <>
      "already know — fetching the user's actual values keeps the workflow runnable. " <>
      "Connectors that haven't implemented deep introspection return `not_supported`; " <>
      "trust the literal in that case."
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
            description: "Fully-qualified function name: `<slug>.<function>`."
          },
          path: %{
            type: "string",
            description:
              "Dotted path into the property you want to inspect (a top-level arg name, or " <>
                "`<arg>.<subfield>` for a nested one). Use the literal property name the " <>
                "function's manifest declares; do not invent."
          }
        },
        required: ["name", "path"]
      }
    }
  end

  @impl true
  def execute(%{"name" => fn_name, "path" => path}, ctx)
      when is_binary(fn_name) and is_binary(path) and path != "" do
    case String.split(fn_name, ".", parts: 2) do
      [slug, bare] ->
        case ConnectorRegistry.module_for_slug(slug) do
          nil ->
            {:error, "inspect_function_property: unknown connector slug `#{slug}`"}

          mod ->
            dispatch_to_connector(mod, slug, bare, path, ctx)
        end

      _ ->
        {:error, "inspect_function_property: `name` must be `<slug>.<function>`"}
    end
  end

  def execute(_, _),
    do: {:error,
         "inspect_function_property: both `name` (string) and `path` (string) are required"}

  # ─── private ─────────────────────────────────────────────────────────

  defp dispatch_to_connector(mod, slug, bare, path, ctx) do
    if function_exported?(mod, :inspect_property, 3) do
      ctx = Map.put(ctx, :vendor_metadata, load_vendor_metadata(slug, ctx))

      case mod.inspect_property(bare, path, ctx) do
        {:ok, schema} when is_map(schema) ->
          {:ok, format(slug, bare, path, schema)}

        {:error, :not_supported} ->
          {:ok,
            %{
              "name"   => "#{slug}.#{bare}",
              "path"   => path,
              "source" => "not_supported",
              "hint"   =>
                "This connector hasn't wired deep property introspection for `#{path}`. " <>
                  "Trust the literal value the user supplied; the runtime will surface a " <>
                  "vendor error if the value isn't valid."
            }}

        {:error, reason} ->
          {:error,
           "inspect_function_property: connector returned `#{inspect(reason)}` " <>
             "for `#{slug}.#{bare}` path=`#{path}`"}
      end
    else
      {:ok,
        %{
          "name"   => "#{slug}.#{bare}",
          "path"   => path,
          "source" => "not_supported",
          "hint"   =>
            "Connector `#{slug}` does not implement property introspection. Trust the literal."
        }}
    end
  end

  defp format(slug, bare, path, schema) do
    %{
      "name"        => "#{slug}.#{bare}",
      "path"        => path,
      "type"        => Map.get(schema, :type) |> to_string_or_nil(),
      "enum"        => Map.get(schema, :enum),
      "description" => Map.get(schema, :description),
      "source"      => Map.get(schema, :source, :manifest) |> to_string()
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp to_string_or_nil(nil),                do: nil
  defp to_string_or_nil(v) when is_atom(v),  do: to_string(v)
  defp to_string_or_nil(v) when is_binary(v), do: v
  defp to_string_or_nil(v),                  do: inspect(v)

  # Load the cached `connector_vendor_metadata` rows for this user +
  # connector and pass them in `ctx[:vendor_metadata]`. The connector's
  # `inspect_property/3` callback decides how to map a (function, path)
  # query onto these rows. Returns `[]` when the user hasn't run
  # Discover Metadata for this connector yet — the connector should
  # treat absence as "no cache, fall back to whatever it knows from
  # the static manifest or return `:not_supported`."
  defp load_vendor_metadata(slug, ctx) do
    case ctx[:user_id] || ctx["user_id"] do
      uid when is_binary(uid) and uid != "" ->
        %{rows: rows} =
          query!(Repo, """
          SELECT path, schema_json
          FROM connector_vendor_metadata
          WHERE connector_slug=? AND user_id=?
          """, [slug, uid])

        Enum.map(rows, fn [path, schema_json] ->
          schema =
            case Jason.decode(schema_json || "{}") do
              {:ok, m} when is_map(m) -> m
              _ -> %{}
            end

          %{path: path, schema: schema}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end
end
