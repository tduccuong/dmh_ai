# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.InspectFunctionTest do
  @moduledoc """
  Pins the contract for the `inspect_function` compile-time tool —
  the model's pre-write window into a connector function's manifest.
  Covers happy paths, the malformed-input rejection, and the
  unknown-function rejection.
  """

  use ExUnit.Case, async: true

  alias DmhAi.Tools.InspectFunction

  describe "happy path" do
    test "returns full contract for a known function" do
      {:ok, out} = InspectFunction.execute(%{"name" => "hubspot.deal.create"}, %{})

      assert out["name"] == "hubspot.deal.create"
      assert out["kind"] == "write"
      assert out["permission"] == "write"
      assert is_map(out["args"])
      assert out["args"]["contact_id"]["required"] == true
      assert out["args"]["contact_id"]["type"] == "string"
      assert out["args"]["amount"]["required"] == true
      assert out["args"]["amount"]["type"] == "number"
      assert out["returns"]["deal_id"] == "string"
      assert is_list(out["scopes_required"])
      assert "crm.objects.deals.write" in out["scopes_required"]
      assert out["idempotency_key"] == "required"
    end

    test "returns args metadata even for read-only functions" do
      {:ok, out} = InspectFunction.execute(%{"name" => "hubspot.contact.find"}, %{})

      assert out["kind"] == "read"
      assert out["args"]["query"]["required"] == true
      assert is_list(out["error_classes"])
    end
  end

  describe "rejection paths" do
    test "unknown function name returns an error envelope" do
      assert {:error, msg} =
               InspectFunction.execute(%{"name" => "hubspot.does_not_exist"}, %{})

      assert msg =~ "no function named"
      assert msg =~ "hubspot.does_not_exist"
    end

    test "unknown slug returns an error envelope" do
      assert {:error, msg} =
               InspectFunction.execute(%{"name" => "no_such_slug.do_something"}, %{})

      assert msg =~ "no function named"
    end

    test "missing name arg returns a clear error" do
      assert {:error, msg} = InspectFunction.execute(%{}, %{})
      assert msg =~ "missing required arg"
    end

    test "name without the slug prefix is rejected" do
      assert {:error, _} = InspectFunction.execute(%{"name" => "deal.create"}, %{})
    end
  end
end
