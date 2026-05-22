# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowExpressionTest do
  @moduledoc """
  Pins the predicate-expression grammar used in `branch.cases[].when`.
  Compile-time validator parses every `when:` and rejects malformed
  expressions; runtime evaluates the AST against the bindings.

  Grammar (one comparison per expression):
    <operand> <op> <operand>
    op       ::= == | != | < | > | <= | >=
    operand  ::= binding | number | string | boolean | null
  """

  use ExUnit.Case, async: true

  alias DmhAi.Workflows.Expression

  describe "parse — happy path" do
    test "binding != null" do
      assert {:ok, {:cmp, "!=", {:binding, "1.contacts[0].id"}, {:literal, nil}}} =
               Expression.parse("{{1.contacts[0].id}} != null")
    end

    test "binding == quoted string" do
      assert {:ok, {:cmp, "==", {:binding, "T.country"}, {:literal, "DE"}}} =
               Expression.parse("{{T.country}} == \"DE\"")
    end

    test "binding > number" do
      assert {:ok, {:cmp, ">", {:binding, "2.amount"}, {:literal, 1000}}} =
               Expression.parse("{{2.amount}} > 1000")
    end

    test "binding == boolean" do
      assert {:ok, {:cmp, "==", {:binding, "1.found"}, {:literal, true}}} =
               Expression.parse("{{1.found}} == true")
    end

    test "all six operators parse" do
      for op <- ["==", "!=", "<", ">", "<=", ">="] do
        assert {:ok, {:cmp, ^op, _, _}} =
                 Expression.parse("{{T.x}} #{op} 5"),
               "operator `#{op}` should parse"
      end
    end
  end

  describe "parse — rejection paths" do
    test "bare binding (no operator) is rejected" do
      assert {:error, msg} = Expression.parse("{{1.contacts.length}}")
      assert msg =~ "must contain exactly one comparison operator"
    end

    test "natural-language predicate is rejected" do
      assert {:error, _} = Expression.parse("no contacts found")
    end

    test "empty operand is rejected" do
      assert {:error, msg} = Expression.parse("{{T.x}} ==")
      assert msg =~ "empty operand"
    end

    test "unknown operand shape is rejected" do
      assert {:error, msg} = Expression.parse("{{T.x}} == soMeThing")
      assert msg =~ "isn't a recognized form"
    end
  end

  describe "evaluate" do
    defp resolver(bindings) do
      fn path ->
        Map.get(bindings, path, :passthrough)
      end
    end

    test "binding != null is true when value is non-nil" do
      {:ok, ast} = Expression.parse("{{1.contact_id}} != null")

      assert Expression.evaluate(ast, resolver(%{"1.contact_id" => "xyz"})) == true
      assert Expression.evaluate(ast, resolver(%{})) == false  # passthrough → nil
    end

    test "numeric comparison" do
      {:ok, ast} = Expression.parse("{{T.amount}} > 1000")

      assert Expression.evaluate(ast, resolver(%{"T.amount" => 2000})) == true
      assert Expression.evaluate(ast, resolver(%{"T.amount" => 500}))  == false
    end

    test "string equality, loose number-to-string" do
      {:ok, ast} = Expression.parse("{{T.code}} == 42")

      assert Expression.evaluate(ast, resolver(%{"T.code" => 42}))   == true
      assert Expression.evaluate(ast, resolver(%{"T.code" => "42"})) == true
      assert Expression.evaluate(ast, resolver(%{"T.code" => 43}))   == false
    end

    test "boolean literal" do
      {:ok, ast} = Expression.parse("{{1.found}} == true")
      assert Expression.evaluate(ast, resolver(%{"1.found" => true}))  == true
      assert Expression.evaluate(ast, resolver(%{"1.found" => false})) == false
    end
  end
end
