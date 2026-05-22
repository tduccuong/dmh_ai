# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Expression do
  @moduledoc """
  Predicate expression grammar for IR `branch.cases[].when` (and any
  future predicate slot). One comparison per expression; both sides
  are operands. Operands are literals, the keyword `null`, the
  booleans `true` / `false`, or Mustache bindings (`{{T.x}}`,
  `{{N.field}}`).

  Grammar (BNF):

      expression  ::= operand op operand
      op          ::= "==" | "!=" | "<" | ">" | "<=" | ">="
      operand     ::= binding | number | string | boolean | "null"
      binding     ::= "{{" path "}}"

  Examples:

      "{{1.contacts[0].id}} != null"
      "{{2.amount}} > 1000"
      "{{T.country}} == \"DE\""
      "{{1.found}} == true"

  No boolean composition (`&&` / `||`), no arithmetic, no function
  calls — keep the grammar small and the validator + executor lean.
  Composition can come later as a separate primitive.

  Used by:
    * `Tools.UpsertWorkflow` (compile-time) — parses every `when:`
      and rejects malformed expressions with a precise error.
    * `Workflows.Executor` (runtime) — evaluates the parsed AST
      against the run's bindings to pick a branch.
  """

  @ops ~w(== != <= >= < >)

  @type ast :: {:cmp, op :: String.t(), operand :: term(), operand :: term()}

  @doc """
  Parse a predicate string into an AST. Returns `{:ok, ast}` or
  `{:error, reason}` — the reason is a sentence the compiler can
  surface verbatim in a validator nudge.
  """
  @spec parse(String.t()) :: {:ok, ast()} | {:error, String.t()}
  def parse(expr) when is_binary(expr) do
    s = String.trim(expr)

    case find_op(s) do
      {:ok, {op, lhs_raw, rhs_raw}} ->
        with {:ok, lhs} <- parse_operand(String.trim(lhs_raw)),
             {:ok, rhs} <- parse_operand(String.trim(rhs_raw)) do
          {:ok, {:cmp, op, lhs, rhs}}
        end

      {:error, _} = err ->
        err
    end
  end

  def parse(_),
    do: {:error, "expression must be a string of shape `<lhs> <op> <rhs>`"}

  @doc """
  Evaluate a parsed AST against a binding-resolver function. The
  caller passes a `resolve_binding` closure that converts a binding
  path (e.g. `"1.contacts[0].id"`, `"T.x"`) into a runtime value.
  Returns a boolean.
  """
  @spec evaluate(ast(), (String.t() -> term())) :: boolean()
  def evaluate({:cmp, op, lhs, rhs}, resolve_binding) do
    a = resolve_value(lhs, resolve_binding)
    b = resolve_value(rhs, resolve_binding)
    compare(op, a, b)
  end

  # ── private ──────────────────────────────────────────────────────────

  # Find the FIRST top-level comparison operator. "Top-level" means
  # outside any `{{...}}` binding (otherwise `{{T.deal_id}} == "5"`
  # would see the `T.deal_id`'s internal characters).
  defp find_op(s) do
    case scan_for_op(s, 0, 0) do
      {:found, op, idx, op_len} ->
        lhs = binary_part(s, 0, idx)
        rhs = binary_part(s, idx + op_len, byte_size(s) - idx - op_len)
        {:ok, {op, lhs, rhs}}

      :not_found ->
        {:error,
         "predicate must contain exactly one comparison operator " <>
           "(==, !=, <, >, <=, >=). Got: #{inspect(s)}. " <>
           "Examples: `{{1.contacts[0].id}} != null`, " <>
           "`{{2.amount}} > 1000`, `{{T.country}} == \"DE\"`."}
    end
  end

  # Scan the string, tracking `{{` / `}}` nesting. The first operator
  # we find OUTSIDE bindings is the comparison op.
  defp scan_for_op(s, idx, _depth) when idx >= byte_size(s), do: :not_found

  defp scan_for_op(s, idx, depth) do
    rest = binary_part(s, idx, byte_size(s) - idx)

    cond do
      String.starts_with?(rest, "{{") ->
        scan_for_op(s, idx + 2, depth + 1)

      String.starts_with?(rest, "}}") ->
        scan_for_op(s, idx + 2, max(depth - 1, 0))

      depth == 0 ->
        case match_op_at(rest) do
          {op, op_len} -> {:found, op, idx, op_len}
          nil -> scan_for_op(s, idx + 1, depth)
        end

      true ->
        scan_for_op(s, idx + 1, depth)
    end
  end

  defp match_op_at(rest) do
    Enum.find_value(@ops, fn op ->
      if String.starts_with?(rest, op), do: {op, byte_size(op)}, else: nil
    end)
  end

  defp parse_operand(""),
    do: {:error, "empty operand — expression has nothing on one side of the operator"}

  defp parse_operand("null"),  do: {:ok, {:literal, nil}}
  defp parse_operand("true"),  do: {:ok, {:literal, true}}
  defp parse_operand("false"), do: {:ok, {:literal, false}}

  defp parse_operand(s) do
    cond do
      String.starts_with?(s, "{{") and String.ends_with?(s, "}}") ->
        path = String.slice(s, 2, byte_size(s) - 4)
        {:ok, {:binding, String.trim(path)}}

      number_literal?(s) ->
        {:ok, {:literal, parse_number(s)}}

      String.starts_with?(s, "\"") and String.ends_with?(s, "\"") ->
        {:ok, {:literal, String.slice(s, 1, byte_size(s) - 2)}}

      String.starts_with?(s, "'") and String.ends_with?(s, "'") ->
        {:ok, {:literal, String.slice(s, 1, byte_size(s) - 2)}}

      true ->
        {:error,
         "operand `#{s}` isn't a recognized form. " <>
           "Use a Mustache binding (`{{1.field}}`, `{{T.x}}`), a number " <>
           "literal (`42`, `1.5`), a quoted string (`\"DE\"`), a boolean " <>
           "(`true` / `false`), or `null`."}
    end
  end

  defp number_literal?(s),
    do: String.match?(s, ~r/^-?\d+(\.\d+)?$/)

  defp parse_number(s) do
    if String.contains?(s, "."),
      do: String.to_float(s),
      else: String.to_integer(s)
  end

  defp resolve_value({:literal, v}, _), do: v
  defp resolve_value({:binding, path}, resolver) do
    case resolver.(path) do
      :passthrough -> nil
      v            -> v
    end
  end

  defp compare("==", a, b), do: equal?(a, b)
  defp compare("!=", a, b), do: not equal?(a, b)
  defp compare("<",  a, b), do: numeric_cmp(a, b, &Kernel.</2)
  defp compare(">",  a, b), do: numeric_cmp(a, b, &Kernel.>/2)
  defp compare("<=", a, b), do: numeric_cmp(a, b, &Kernel.<=/2)
  defp compare(">=", a, b), do: numeric_cmp(a, b, &Kernel.>=/2)

  # Equality is loose — string "42" matches numeric 42 because the
  # runtime sometimes returns one form, sometimes the other depending
  # on the source (JSON-decoded vs Elixir-native).
  defp equal?(a, b) when is_binary(a) and is_number(b) do
    if number_literal?(a),
      do: parse_number(a) == b,
      else: a == "#{b}"
  end

  defp equal?(a, b) when is_number(a) and is_binary(b), do: equal?(b, a)
  defp equal?(nil, ""),  do: true
  defp equal?("",  nil), do: true
  defp equal?(a, b),     do: a == b

  defp numeric_cmp(a, b, op) when is_number(a) and is_number(b), do: op.(a, b)

  defp numeric_cmp(a, b, op) when is_binary(a) and is_binary(b) do
    cond do
      number_literal?(a) and number_literal?(b) ->
        op.(parse_number(a), parse_number(b))

      true ->
        op.(a, b)
    end
  end

  defp numeric_cmp(a, b, op) when is_binary(a) and is_number(b) do
    if number_literal?(a), do: op.(parse_number(a), b), else: false
  end

  defp numeric_cmp(a, b, op) when is_number(a) and is_binary(b) do
    if number_literal?(b), do: op.(a, parse_number(b)), else: false
  end

  defp numeric_cmp(_, _, _), do: false
end
