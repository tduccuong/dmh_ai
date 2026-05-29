# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Shopify do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Shopify connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  Sentinel identifiers (German fake store + product / order IDs)
  let runbooks + tests assert mechanically that the chain's output
  came from the connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "product.find"       => &product_find/1,
      "product.create"     => &product_create/1,
      "product.update"     => &product_update/1,
      "order.find"         => &order_find/1,
      "order.fulfill"      => &order_fulfill/1,
      "customer.find"      => &customer_find/1,
      "customer.create"    => &customer_create/1,
      "inventory.adjust"   => &inventory_adjust/1,
      "draft_order.create" => &draft_order_create/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      shop_name:        "Beispiel Laden GmbH",
      product_title:    "Bio-Baumwoll Kapuzenpullover",
      product_id:       "shopify_product_mock_001",
      order_name:       "#1042",
      order_id:         "shopify_order_mock_002",
      fulfillment_id:   "shopify_fulfillment_mock_003",
      customer_name:    "Klara Beispielkundin",
      customer_email:   "klara.kundin@beispiel-laden-demo.example",
      customer_id:      "shopify_customer_mock_004",
      inventory_item_id: "shopify_invitem_mock_005",
      location_id:      "shopify_location_mock_006",
      draft_order_id:   "shopify_draftorder_mock_007"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp product_find(_args) do
    %{product_id: id, product_title: title, shop_name: vendor} = sentinels()

    %{
      "products" => [
        %{
          "id"     => id,
          "title"  => title,
          "vendor" => vendor,
          "status" => "active"
        }
      ]
    }
  end

  defp product_create(args) do
    %{product_id: id} = sentinels()

    %{
      "product_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "title"      => Map.get(args, "title", "Untitled product")
    }
  end

  defp product_update(args) do
    %{
      "product_id" => Map.get(args, "product_id"),
      "updated"    => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp order_find(_args) do
    %{order_id: id, order_name: name} = sentinels()

    %{
      "orders" => [
        %{
          "id"                 => id,
          "name"               => name,
          "financial_status"   => "paid",
          "fulfillment_status" => nil,
          "total_price"        => "49.90"
        }
      ]
    }
  end

  defp order_fulfill(_args) do
    %{fulfillment_id: id} = sentinels()

    %{
      "fulfillment_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp customer_find(_args) do
    %{customer_id: id, customer_name: name, customer_email: email} = sentinels()

    %{
      "customers" => [
        %{
          "id"    => id,
          "name"  => name,
          "email" => email
        }
      ]
    }
  end

  defp customer_create(args) do
    %{customer_id: id} = sentinels()

    %{
      "customer_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "email"       => Map.get(args, "email")
    }
  end

  defp inventory_adjust(args) do
    %{location_id: loc} = sentinels()

    %{
      "inventory_level" => %{
        "inventory_item_id" => Map.get(args, "inventory_item_id"),
        "location_id"       => Map.get(args, "location_id", loc),
        "available"         => Map.get(args, "available_adjustment", 0)
      }
    }
  end

  defp draft_order_create(_args) do
    %{draft_order_id: id} = sentinels()

    %{
      "draft_order_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end
end
