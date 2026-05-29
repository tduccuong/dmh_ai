# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowsRefsEngineTest do
  @moduledoc """
  Unit tests for the workflow IR's reference engine — the three
  modules under `lib/dmh_ai/workflows/`:

    * `Mustache` — scans a string into `{:literal, …}` + `{:ref, …}`
      chunks; renders via a resolver.
    * `Path` — parses a ref body into a typed accessor sequence;
      walks data structures.
    * `Refs` — composes the above over arbitrary args values.

  Tests exercise:
    - the grammar in its full form (idents, ints, brackets, mixed)
    - deeply nested paths (8+ accessors)
    - templates with multiple refs
    - bare-ref typed return vs template stringification
    - error paths (unclosed mustache, bad bracket, empty bracket, …)
    - the deep recursion over nested maps + lists
  """

  use ExUnit.Case, async: true

  alias DmhAi.Workflows.{Mustache, Path, Refs}

  # ── Mustache scanner ────────────────────────────────────────────────

  describe "Mustache.scan/1 — basic grammar" do
    test "plain literal — no refs" do
      assert {:ok, [{:literal, "hello world"}]} = Mustache.scan("hello world")
    end

    test "bare ref" do
      assert {:ok, [{:ref, "0.foo"}]} = Mustache.scan("{{0.foo}}")
    end

    test "ref body is trimmed" do
      assert {:ok, [{:ref, "0.foo"}]} = Mustache.scan("{{ 0.foo }}")
    end

    test "template with single ref" do
      assert {:ok, [{:literal, "Hello "}, {:ref, "owner.name"}, {:literal, "!"}]} =
               Mustache.scan("Hello {{owner.name}}!")
    end

    test "template with three refs" do
      assert {:ok, chunks} =
               Mustache.scan("{{T.a}} and {{1.b}} and {{owner.name}}")

      assert length(Enum.filter(chunks, &match?({:ref, _}, &1))) == 3
      assert {:ref, "T.a"}        in chunks
      assert {:ref, "1.b"}        in chunks
      assert {:ref, "owner.name"} in chunks
    end

    test "stray single `{` and `}` pass through as literals" do
      assert {:ok, [{:literal, "a{b}c"}]} = Mustache.scan("a{b}c")
    end

    test "unclosed `{{` is an error, not silent truncation" do
      assert {:error, msg} = Mustache.scan("hello {{0.foo")
      assert msg =~ "unclosed"
    end

    test "doubled `}}` outside a ref is plain text" do
      assert {:ok, [{:literal, "no }} here"}]} = Mustache.scan("no }} here")
    end
  end

  describe "Mustache.render/2 — bare vs template" do
    test "bare ref returns TYPED value from resolver (not stringified)" do
      # When the resolver returns a list, render returns a list.
      result = Mustache.render("{{0.items}}", fn _body -> [1, 2, 3] end)
      assert result == [1, 2, 3]
    end

    test "bare ref with surrounding whitespace still returns typed value" do
      result = Mustache.render("  {{0.items}}  ", fn _body -> %{a: 1} end)
      assert result == %{a: 1}
    end

    test "template with multiple refs renders to STRING" do
      resolver = fn
        "owner.name"  -> "Alice"
        "0.count"     -> 7
        _other        -> :passthrough
      end

      assert Mustache.render("Hello {{owner.name}}, you have {{0.count}} items.", resolver) ==
               "Hello Alice, you have 7 items."
    end

    test "passthrough leaves the ref in place (template path)" do
      assert Mustache.render("a {{0.foo}} b", fn _ -> :passthrough end) ==
               "a {{0.foo}} b"
    end

    test "passthrough on bare ref leaves the original string" do
      assert Mustache.render("  {{0.foo}}  ", fn _ -> :passthrough end) ==
               "  {{0.foo}}  "
    end
  end

  # ── Path tokeniser ──────────────────────────────────────────────────

  describe "Path.parse/1 — single-segment roots" do
    test "T → trigger root, empty path" do
      # `T` alone (without a dotted suffix) isn't valid grammar; T must
      # be followed by `.` or by end-of-input. The minimal trigger ref
      # `T` alone is treated as root with empty path:
      assert {:ok, %{root: :trigger, path: []}} = Path.parse("T")
    end

    test "owner alone → owner root, empty path" do
      assert {:ok, %{root: :owner, path: []}} = Path.parse("owner")
    end

    test "now / today → unique roots, empty path" do
      assert {:ok, %{root: :now,   path: []}} = Path.parse("now")
      assert {:ok, %{root: :today, path: []}} = Path.parse("today")
    end

    test "now / today offset → {root, seconds} tuple, empty path" do
      assert {:ok, %{root: {:now, -604_800}, path: []}} = Path.parse("now-7d")
      assert {:ok, %{root: {:now, 3_600},     path: []}} = Path.parse("now+1h")
      assert {:ok, %{root: {:today, 604_800},  path: []}} = Path.parse("today+1w")
      assert {:ok, %{root: {:today, -86_400},  path: []}} = Path.parse("today-1d")
    end

    test "offset form rejects a trailing path (now/today are scalar)" do
      assert {:error, msg} = Path.parse("now-7d.foo")
      assert msg =~ "offset only"
    end

    test "bare integer → node root, empty path" do
      assert {:ok, %{root: {:node, 7}, path: []}} = Path.parse("7")
    end
  end

  describe "Path.parse/1 — basic dotted paths" do
    test "T.deal.contact.email" do
      assert {:ok, %{root: :trigger, path: path}} = Path.parse("T.deal.contact.email")
      assert path == [{:key, "deal"}, {:key, "contact"}, {:key, "email"}]
    end

    test "0.messages.sender (dot-form, no brackets)" do
      assert {:ok, %{root: {:node, 0}, path: path}} = Path.parse("0.messages.sender")
      assert path == [{:key, "messages"}, {:key, "sender"}]
    end

    test "owner.email" do
      assert {:ok, %{root: :owner, path: [{:key, "email"}]}} = Path.parse("owner.email")
    end
  end

  describe "Path.parse/1 — bracket-index syntax" do
    test "0.messages[0].sender" do
      assert {:ok, %{root: {:node, 0}, path: path}} = Path.parse("0.messages[0].sender")
      assert path == [{:key, "messages"}, {:index, 0}, {:key, "sender"}]
    end

    test "0.messages.0.sender (dot-int form is equivalent semantically)" do
      assert {:ok, %{root: {:node, 0}, path: path}} = Path.parse("0.messages.0.sender")
      assert path == [{:key, "messages"}, {:index, 0}, {:key, "sender"}]
    end

    test "adjacent brackets — list-of-lists" do
      assert {:ok, %{root: {:node, 0}, path: path}} = Path.parse("0.matrix[2][3]")
      assert path == [{:key, "matrix"}, {:index, 2}, {:index, 3}]
    end

    test "brackets at end" do
      assert {:ok, %{root: {:node, 0}, path: path}} = Path.parse("0.tags[5]")
      assert path == [{:key, "tags"}, {:index, 5}]
    end
  end

  describe "Path.parse/1 — deep paths (8+ accessors, the 95% case)" do
    test "all-key chain" do
      assert {:ok, %{path: path}} =
               Path.parse("0.api.response.data.user.profile.contact.email.primary")

      assert length(path) == 8
      Enum.each(path, fn p -> assert match?({:key, _}, p) end)
    end

    test "mixed key + bracket-index chain" do
      ref = "0.api.data.items[5].user.profile.emails[0].address"
      assert {:ok, %{root: {:node, 0}, path: path}} = Path.parse(ref)

      assert path == [
               {:key,   "api"},
               {:key,   "data"},
               {:key,   "items"},
               {:index, 5},
               {:key,   "user"},
               {:key,   "profile"},
               {:key,   "emails"},
               {:index, 0},
               {:key,   "address"}
             ]
    end

    test "alternating bracket-index forms — dot-numeric AND bracket are equivalent" do
      {:ok, a} = Path.parse("0.data.items.5.user")
      {:ok, b} = Path.parse("0.data.items[5].user")
      assert a.path == b.path
    end

    test "absurdly deep + nested brackets" do
      ref = "12.a.b.c[0].d.e[1][2].f.g.h"
      assert {:ok, %{root: {:node, 12}, path: path}} = Path.parse(ref)
      assert length(path) == 11
    end
  end

  describe "Path.parse/1 — error paths" do
    test "double dot" do
      assert {:error, msg} = Path.parse("0..foo")
      assert msg =~ "expected"
    end

    test "non-numeric inside brackets" do
      assert {:error, msg} = Path.parse("0.foo[bar]")
      assert msg =~ "bracket" or msg =~ "only digits"
    end

    test "empty brackets" do
      assert {:error, msg} = Path.parse("0.foo[]")
      assert msg =~ "empty"
    end

    test "unclosed bracket" do
      assert {:error, msg} = Path.parse("0.foo[1")
      assert msg =~ "unclosed"
    end

    test "ref starting with `[`" do
      assert {:error, _} = Path.parse("[0]")
    end

    test "trailing dot" do
      assert {:error, _} = Path.parse("0.foo.")
    end

    test "unknown root parses as :local (template-local placeholder)" do
      # NOT an error — refs like `{{name}}` or `{{some_local.x}}` inside
      # an llm.compose template are template-local placeholders the
      # synthetic primitive resolves itself. The validator skips them
      # and the executor passes them through unchanged.
      assert {:ok, %{root: :local, path: path}} = Path.parse("invalid_root.foo")
      assert path == [{:key, "invalid_root"}, {:key, "foo"}]
    end

    test "bare ident parses as :local" do
      assert {:ok, %{root: :local, path: [{:key, "name"}]}} = Path.parse("name")
    end
  end

  # ── Path.walk/2 ─────────────────────────────────────────────────────

  describe "Path.walk/2 — map + list traversal" do
    @data %{
      "api" => %{
        "data" => %{
          "items" => [
            %{"user" => %{"profile" => %{"emails" => [%{"address" => "a@x"}, %{"address" => "b@x"}]}}},
            %{"user" => %{"profile" => %{"emails" => [%{"address" => "c@x"}]}}}
          ]
        }
      },
      "matrix" => [[10, 11, 12], [20, 21, 22], [30, 31, 32]]
    }

    test "deep key+index chain" do
      {:ok, parsed} = Path.parse("0.api.data.items[0].user.profile.emails[1].address")
      assert Path.walk(@data, parsed.path) == "b@x"
    end

    test "list-of-lists indexing" do
      {:ok, parsed} = Path.parse("0.matrix[1][2]")
      assert Path.walk(@data, parsed.path) == 22
    end

    test "out-of-range index returns {:index_miss, i}" do
      {:ok, parsed} = Path.parse("0.matrix[99][0]")
      # The executor surfaces this as a `:lookup_miss` step failure
      # rather than silently passing the empty value downstream.
      assert Path.walk(@data, parsed.path) == {:index_miss, 99}
    end

    test "missing key returns :not_found" do
      {:ok, parsed} = Path.parse("0.no_such_field.foo")
      assert Path.walk(@data, parsed.path) == :not_found
    end

    test "type mismatch (asking for index on a map) returns :not_found" do
      {:ok, parsed} = Path.parse("0.api[0]")
      assert Path.walk(@data, parsed.path) == :not_found
    end
  end

  # ── Refs (composition) ──────────────────────────────────────────────

  describe "Refs.extract/1 — recursive over args" do
    test "flat map with one ref-bearing string" do
      args = %{"to" => "{{owner.email}}", "subject" => "Hi"}
      extracted = Refs.extract(args)
      raw = Enum.map(extracted, & &1.raw)
      assert "owner.email" in raw
    end

    test "deeply nested map with multiple ref-bearing strings" do
      args = %{
        "context" => %{
          "user" => %{
            "name"  => "{{0.user.name}}",
            "email" => "{{T.email}}"
          },
          "items" => ["{{1.first}}", "static", "{{1.second}}"]
        },
        "template" => "Hello {{owner.name}}, you have {{1.count}} items"
      }

      extracted = Refs.extract(args)
      raw = Enum.map(extracted, & &1.raw) |> Enum.sort()

      assert raw == [
               "0.user.name",
               "1.count",
               "1.first",
               "1.second",
               "T.email",
               "owner.name"
             ]
    end

    test "scalar args (numbers, nil, bool) produce no refs" do
      assert Refs.extract(%{"a" => 1, "b" => nil, "c" => true}) == []
      assert Refs.extract([1, 2, 3]) == []
      assert Refs.extract("plain literal, no refs") == []
    end

    test "malformed mustache surfaces as :error entry" do
      args = %{"to" => "{{owner.email"}    # unclosed
      [entry] = Refs.extract(args)
      assert Map.has_key?(entry, :error)
    end

    test "bracket-syntax refs parse correctly during extraction" do
      args = %{"email" => "{{0.messages[0].sender}}"}
      [entry] = Refs.extract(args)
      assert entry.parsed.root == {:node, 0}
      assert {:index, 0} in entry.parsed.path
    end
  end

  describe "Refs.substitute/2 — recursive over args" do
    test "deeply nested substitution preserves structure" do
      args = %{
        "context" => %{
          "user_name" => "{{T.user}}",
          "items"     => ["{{0.a}}", "{{0.b}}"]
        },
        "subject"   => "Update for {{T.user}}"
      }

      resolver = fn
        "T.user" -> "Alice"
        "0.a"    -> "alpha"
        "0.b"    -> "beta"
      end

      out = Refs.substitute(args, resolver)

      assert out["subject"] == "Update for Alice"
      assert out["context"]["user_name"] == "Alice"
      assert out["context"]["items"] == ["alpha", "beta"]
    end

    test "bare ref preserves typed (non-string) return" do
      args = %{"payload" => "{{0.user}}"}
      resolver = fn "0.user" -> %{"id" => 7, "name" => "Alice"} end
      out = Refs.substitute(args, resolver)
      assert out["payload"] == %{"id" => 7, "name" => "Alice"}
    end

    test "passthrough leaves the placeholder intact (synthetic primitives use this)" do
      args = %{"template" => "Hi {{x}}", "context" => %{"x" => "{{0.name}}"}}
      resolver = fn
        "0.name" -> "Bob"
        "x"      -> :passthrough     # `x` is a template-local placeholder, not a runtime ref
      end

      out = Refs.substitute(args, resolver)
      assert out["template"] == "Hi {{x}}"
      assert out["context"]["x"] == "Bob"
    end
  end
end
