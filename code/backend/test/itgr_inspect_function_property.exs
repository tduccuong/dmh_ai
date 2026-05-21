# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.InspectFunctionPropertyTest do
  @moduledoc """
  Pins the `inspect_function_property` tool's framework — Layer 2 in
  arch_wiki/dmh_ai/sme/layer-W.md. Covers:

    * Graceful "not_supported" fallthrough when the connector hasn't
      implemented deep introspection (current default for all
      connectors). The compiler treats this as "trust the literal".
    * Error envelopes for unknown slug / malformed input.

  The success path — `{:ok, %{type, enum, source: "vendor_metadata"}}`
  from a connector that wires `inspect_property/3` — lands with the
  first connector that ships a real implementation (per-connector
  follow-up; see `arch_wiki/dmh_ai/sme/layer-W.md` §L2).
  """

  use ExUnit.Case, async: true

  alias DmhAi.Tools.InspectFunctionProperty

  describe "fallthrough for connectors that don't implement inspect_property" do
    test "default callback returns `not_supported` envelope (trust the literal)" do
      assert {:ok, out} =
               InspectFunctionProperty.execute(
                 %{"name" => "hubspot.deal.create", "path" => "dealstage"}, %{})

      assert out["source"] == "not_supported"
      assert out["hint"]   =~ "Trust the literal"
      assert out["name"]   == "hubspot.deal.create"
      assert out["path"]   == "dealstage"
    end

    test "fallthrough works on deep dotted paths too" do
      assert {:ok, out} =
               InspectFunctionProperty.execute(
                 %{"name" => "google_workspace.calendar.event.create",
                   "path" => "recurrence.frequency"}, %{})

      assert out["source"] == "not_supported"
      assert out["path"]   == "recurrence.frequency"
    end
  end

  describe "rejection paths" do
    test "unknown slug" do
      assert {:error, msg} =
               InspectFunctionProperty.execute(
                 %{"name" => "no_such.thing", "path" => "x"}, %{})

      assert msg =~ "unknown connector slug"
    end

    test "missing `path`" do
      assert {:error, msg} =
               InspectFunctionProperty.execute(
                 %{"name" => "hubspot.deal.create"}, %{})

      assert msg =~ "required"
    end

    test "missing `name`" do
      assert {:error, msg} =
               InspectFunctionProperty.execute(%{"path" => "x"}, %{})

      assert msg =~ "required"
    end

    test "malformed name (no slug separator) returns a clear error" do
      assert {:error, msg} =
               InspectFunctionProperty.execute(
                 %{"name" => "dealstage", "path" => "x"}, %{})

      # `String.split("dealstage", ".", parts: 2)` returns `["dealstage"]`
      # which doesn't match `[slug, bare]` → falls through to the
      # connector lookup which fails on the empty bare name.
      assert msg =~ "unknown connector slug" or msg =~ "must be"
    end

    test "empty path is rejected" do
      assert {:error, msg} =
               InspectFunctionProperty.execute(
                 %{"name" => "hubspot.deal.create", "path" => ""}, %{})

      assert msg =~ "required"
    end
  end
end
