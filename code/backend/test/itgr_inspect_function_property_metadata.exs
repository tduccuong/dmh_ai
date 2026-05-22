# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.InspectFunctionPropertyMetadataTest do
  @moduledoc """
  Pins the Layer B reader path: `inspect_function_property` consults
  the `connector_vendor_metadata` cache (populated by Discovery's
  metadata layer) before falling through to the connector's live
  probe. HubSpot is the first implementer — verifies that an
  out-of-the-manifest enum value (a custom HubSpot property the
  user added on their portal) becomes visible to the compiler.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Tools.InspectFunctionProperty
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    user_id = T.uid()
    slug    = "hubspot"

    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "ifp-#{user_id}@test.local", "Test", "x:y", "user",
       DmhAi.Constants.default_org_id(), "member", :os.system_time(:second)])

    # Seed a cached metadata row for `crm.properties.deals` carrying
    # both a stock HubSpot property (`dealstage`) AND a fictional
    # custom property (`industry_sector`) so the test exercises both
    # discovery paths.
    schema =
      %{
        "object_type" => "deals",
        "properties"  => [
          %{
            "name"      => "dealstage",
            "label"     => "Deal Stage",
            "type"      => "enumeration",
            "fieldType" => "select",
            "options"   => [
              %{"label" => "Appointment scheduled", "value" => "appointmentscheduled"},
              %{"label" => "Closed Won",            "value" => "closedwon"}
            ]
          },
          %{
            "name"      => "industry_sector",
            "label"     => "Industry Sector",
            "type"      => "enumeration",
            "fieldType" => "select",
            "options"   => [
              %{"label" => "SaaS",          "value" => "saas"},
              %{"label" => "Manufacturing", "value" => "manufacturing"}
            ]
          }
        ]
      }

    query!(Repo, """
    INSERT INTO connector_vendor_metadata
      (connector_slug, user_id, path, schema_json, discovered_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?)
    """, [slug, user_id, "crm.properties.deals", Jason.encode!(schema),
          System.os_time(:millisecond), nil])

    on_exit(fn ->
      query!(Repo, "DELETE FROM connector_vendor_metadata WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, user_id: user_id, slug: slug}
  end

  describe "Layer B reader" do
    test "resolves a stock HubSpot property's enum from the cache",
         %{user_id: user_id} do
      assert {:ok, out} =
               InspectFunctionProperty.execute(
                 %{"name" => "hubspot.deal.create", "path" => "dealstage"},
                 %{user_id: user_id})

      assert out["name"]   == "hubspot.deal.create"
      assert out["path"]   == "dealstage"
      assert out["type"]   == "enumeration"
      assert out["source"] == "vendor_metadata"
      assert "appointmentscheduled" in out["enum"]
      assert "closedwon" in out["enum"]
    end

    test "resolves a custom property added on the user's portal",
         %{user_id: user_id} do
      assert {:ok, out} =
               InspectFunctionProperty.execute(
                 %{"name" => "hubspot.deal.update", "path" => "industry_sector"},
                 %{user_id: user_id})

      assert out["source"] == "vendor_metadata"
      assert out["enum"]   == ["saas", "manufacturing"]
    end

    test "returns :not_supported when the property isn't in the cache",
         %{user_id: user_id} do
      assert {:ok, out} =
               InspectFunctionProperty.execute(
                 %{"name" => "hubspot.deal.create", "path" => "does_not_exist"},
                 %{user_id: user_id})

      assert out["source"] == "not_supported"
    end

    test "returns :not_supported when the function isn't mapped to an object",
         %{user_id: user_id} do
      # `hubspot.contact.find` IS mapped, but to `contacts`. The cache
      # only has the `deals` row in this test setup, so the lookup
      # falls through to `:not_supported`.
      assert {:ok, out} =
               InspectFunctionProperty.execute(
                 %{"name" => "hubspot.contact.find", "path" => "lifecyclestage"},
                 %{user_id: user_id})

      assert out["source"] == "not_supported"
    end

    test "returns :not_supported when the user has no cached metadata at all" do
      # New user_id with no rows in connector_vendor_metadata.
      uid_fresh = T.uid()

      assert {:ok, out} =
               InspectFunctionProperty.execute(
                 %{"name" => "hubspot.deal.create", "path" => "dealstage"},
                 %{user_id: uid_fresh})

      assert out["source"] == "not_supported"
    end
  end
end
