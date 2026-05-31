# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Police.Schema do
  @moduledoc """
  Tool-call schema gate. Validates a tool call's arguments against the
  tool's own declared schema (`DmhAi.Tools.Registry.definition_for/1`).
  Generic — no per-tool pattern rules. Catches missing required fields
  and wrong argument types (loose: string / integer / array / boolean).

  Builds a schema-driven nudge on rejection so the model sees the
  correct call shape constructed from the tool's own property
  descriptions.
  """

  require Logger

  alias DmhAi.Tools.Registry

  @doc """
  Validate a tool call's arguments against the tool's own declared
  schema. Returns `:ok` or `{:rejected, {:tool_call_schema, reason}}`
  where `reason` is a schema-driven nudge showing the correct call
  shape built from the tool's own property descriptions.
  """
  @spec check_tool_call_schema(String.t(), map()) :: :ok | {:rejected, {:tool_call_schema, String.t()}}
  def check_tool_call_schema(name, args) when is_binary(name) and is_map(args) do
    case Registry.definition_for(name) do
      nil ->
        :ok

      schema ->
        params    = schema[:parameters] || %{}
        props     = params[:properties] || %{}
        required  = params[:required] || []

        missing = Enum.reject(required, fn k -> present_and_non_empty?(args[to_string(k)]) end)

        type_errs =
          Enum.flat_map(props, fn {key, prop} ->
            expected = prop[:type]
            actual   = args[to_string(key)]

            cond do
              is_nil(actual) -> []
              type_ok?(expected, actual) -> []
              true -> [%{field: to_string(key), expected: expected, got: actual_type(actual)}]
            end
          end)

        if missing == [] and type_errs == [] do
          :ok
        else
          reason = build_schema_nudge(name, schema, missing, type_errs)
          Logger.warning("[Police] REJECTED tool_call_schema: tool=#{name} missing=#{inspect(missing)} type_errs=#{inspect(type_errs)}")
          DmhAi.SysLog.log("[POLICE] REJECTED tool_call_schema: tool=#{name} missing=#{inspect(missing)} type_errs=#{inspect(type_errs)}")
          {:rejected, {:tool_call_schema, reason}}
        end
    end
  end
  def check_tool_call_schema(_, _), do: :ok

  # ── private helpers ─────────────────────────────────────────────────────

  defp present_and_non_empty?(nil), do: false
  defp present_and_non_empty?(""),  do: false
  defp present_and_non_empty?([]),  do: false
  defp present_and_non_empty?(_),   do: true

  defp type_ok?("string",  v), do: is_binary(v)
  defp type_ok?("integer", v), do: is_integer(v) or (is_binary(v) and match?({_, ""}, Integer.parse(v)))
  defp type_ok?("number",  v), do: is_number(v)
  defp type_ok?("boolean", v), do: is_boolean(v)
  defp type_ok?("array",   v), do: is_list(v)
  defp type_ok?("object",  v), do: is_map(v)
  defp type_ok?(_, _),         do: true

  defp actual_type(v) when is_binary(v),  do: "string"
  defp actual_type(v) when is_integer(v), do: "integer"
  defp actual_type(v) when is_number(v),  do: "number"
  defp actual_type(v) when is_boolean(v), do: "boolean"
  defp actual_type(v) when is_list(v),    do: "array"
  defp actual_type(v) when is_map(v),     do: "object"
  defp actual_type(_),                    do: "unknown"

  defp build_schema_nudge(name, schema, missing, type_errs) do
    props    = get_in(schema, [:parameters, :properties]) || %{}
    required = get_in(schema, [:parameters, :required])   || []

    complaint =
      cond do
        missing != [] and type_errs != [] ->
          "missing required field(s): #{Enum.join(missing, ", ")}; wrong type(s): " <>
            (Enum.map_join(type_errs, ", ", fn e ->
              "#{e.field} expected #{e.expected} got #{e.got}"
            end))

        missing != [] ->
          "missing required field(s): #{Enum.join(missing, ", ")}"

        true ->
          "wrong type(s): " <>
            Enum.map_join(type_errs, ", ", fn e ->
              "#{e.field} expected #{e.expected} got #{e.got}"
            end)
      end

    example = render_schema_example(name, props, required)

    "Malformed tool_call for `#{name}`: #{complaint}.\n\n" <>
      "Correct shape (placeholders show types; fill in real values):\n\n" <>
      example <>
      "\n\nRetry the call with every required field present and correctly typed."
  end

  defp render_schema_example(name, props, required) do
    lines =
      Enum.map_join(props, "\n", fn {key, prop} ->
        expected_type = prop[:type] || "string"
        desc          = prop[:description] || ""
        req?          = to_string(key) in Enum.map(required, &to_string/1)
        marker        = if req?, do: "(required)", else: "(optional)"
        placeholder   = type_placeholder(expected_type)
        "  \"#{key}\": #{placeholder},  // #{marker} #{desc}"
      end)

    "#{name}({\n#{lines}\n})"
  end

  defp type_placeholder("string"),  do: "\"<string>\""
  defp type_placeholder("integer"), do: "<integer>"
  defp type_placeholder("number"),  do: "<number>"
  defp type_placeholder("boolean"), do: "<true|false>"
  defp type_placeholder("array"),   do: "[\"<string>\", …]"
  defp type_placeholder("object"),  do: "{…}"
  defp type_placeholder(_),         do: "<value>"
end
