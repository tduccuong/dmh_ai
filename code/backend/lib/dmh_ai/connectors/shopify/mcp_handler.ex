# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Shopify.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Shopify connector consumed by the
  generic `Connectors.MCPServer`. Each function is a 1:1 mapping
  to a Shopify Admin REST endpoint at `{shop}.myshopify.com/admin/
  api/2024-01/*`:

    product.find       — GET  /products.json
    product.create     — POST /products.json
    product.update     — PUT  /products/{id}.json
    order.find         — GET  /orders.json
    order.fulfill      — POST /fulfillments.json
    customer.find      — GET  /customers/search.json
    customer.create    — POST /customers.json
    inventory.adjust   — POST /inventory_levels/adjust.json
    draft_order.create — POST /draft_orders.json

  Shopify's read endpoints are GET-with-querystring (`?query=` /
  `?status=` / `?limit=`), not the POST-with-body search style
  HubSpot uses. The response carries a resource-named array
  (`products` / `orders` / `customers`) which we flatten to the
  canonical `{id, title, …}` shape so the model treats every
  storefront the same regardless of vendor.

  `{shop}` in `@api_base` is a placeholder — live calls require the
  framework to template the merchant's shop domain before dispatch.
  The mock vendor server answers by function name, not URL, so it is
  exercised without substitution.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  require Logger

  @api_base "https://{shop}.myshopify.com/admin/api/2024-01"

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "shopify", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "product.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/products.json",
        request: &product_find_request/2,
        response: &product_find_response/2,
        doc:     "Search Shopify products; returns title + vendor + id."
      },
      "product.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/products.json",
        request: &product_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"product_id" => to_string(get_in(body, ["product", "id"])),
                            "title" => get_in(body, ["product", "title"])}}
                  end,
        doc:     "Create a product."
      },
      "product.update" => %FunctionSpec{
        handler: &product_update/2,
        doc:     "Patch product fields (price, vendor, body_html, …)."
      },
      "order.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/orders.json",
        request: &order_find_request/2,
        response: &order_find_response/2,
        doc:     "List Shopify orders; filter by status."
      },
      "order.fulfill" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/fulfillments.json",
        request: &order_fulfill_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"fulfillment_id" => to_string(get_in(body, ["fulfillment", "id"]))}}
                  end,
        doc:     "Fulfil an order with optional tracking."
      },
      "customer.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/customers/search.json",
        request: &customer_find_request/2,
        response: &customer_find_response/2,
        doc:     "Search Shopify customers; returns name + email + id."
      },
      "customer.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/customers.json",
        request: &customer_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"customer_id" => to_string(get_in(body, ["customer", "id"])),
                            "email" => get_in(body, ["customer", "email"])}}
                  end,
        doc:     "Create a customer by email."
      },
      "inventory.adjust" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/inventory_levels/adjust.json",
        request: &inventory_adjust_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"inventory_level" => Map.get(body, "inventory_level", %{})}}
                  end,
        doc:     "Adjust an inventory level at a location."
      },
      "draft_order.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/draft_orders.json",
        request: &draft_order_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"draft_order_id" => to_string(get_in(body, ["draft_order", "id"]))}}
                  end,
        doc:     "Create a draft order (cart / quote)."
      }
    }
  end

  # ─── product.find — GET search ────────────────────────────────────────

  defp product_find_request(args, _ctx) do
    params =
      %{"limit" => Map.get(args, "limit", 10)}
      |> maybe_put_kv("title", Map.get(args, "query"))

    [params: params]
  end

  defp product_find_response(s, body) when s in 200..299 do
    products =
      Map.get(body, "products", [])
      |> Enum.map(&normalise_product/1)

    {:ok, %{"products" => products}}
  end

  defp normalise_product(p) do
    %{
      "id"     => to_string(p["id"]),
      "title"  => p["title"],
      "vendor" => p["vendor"],
      "status" => p["status"]
    }
  end

  # ─── product.create — POST create ─────────────────────────────────────

  defp product_create_request(args, _ctx) do
    product =
      %{"title" => args["title"]}
      |> maybe_put_kv("body_html", Map.get(args, "body_html"))
      |> maybe_put_kv("vendor",    Map.get(args, "vendor"))

    # Shopify carries price on a variant, not the product root. When
    # the agent supplies a price, seed a default variant with it.
    product =
      case Map.get(args, "price") do
        nil -> product
        p   -> Map.put(product, "variants", [%{"price" => to_string(p)}])
      end

    [json: %{"product" => product}]
  end

  # ─── product.update — PUT with dynamic URL ────────────────────────────

  defp product_update(args, ctx) do
    patch = args["patch"] || %{}
    url   = "#{@api_base}/products/#{URI.encode(to_string(args["product_id"]))}.json"
    opts  = [url: url, json: %{"product" => patch}]

    case RestBridge.raw_request(:put, with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, %{"product_id" => to_string(get_in(body, ["product", "id"]) || args["product_id"]),
                "updated" => Map.keys(patch)}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  # ─── order.find — GET list ────────────────────────────────────────────

  defp order_find_request(args, _ctx) do
    params =
      %{"limit" => Map.get(args, "limit", 10)}
      |> maybe_put_kv("status", Map.get(args, "status"))

    [params: params]
  end

  defp order_find_response(s, body) when s in 200..299 do
    orders =
      Map.get(body, "orders", [])
      |> Enum.map(&normalise_order/1)

    {:ok, %{"orders" => orders}}
  end

  defp normalise_order(o) do
    %{
      "id"               => to_string(o["id"]),
      "name"             => o["name"],
      "financial_status" => o["financial_status"],
      "fulfillment_status" => o["fulfillment_status"],
      "total_price"      => o["total_price"]
    }
  end

  # ─── order.fulfill — POST fulfilment ──────────────────────────────────

  defp order_fulfill_request(args, _ctx) do
    fulfillment =
      %{
        "line_items_by_fulfillment_order" => [
          %{"fulfillment_order_id" => args["order_id"]}
        ]
      }

    fulfillment =
      case Map.get(args, "tracking_number") do
        t when is_binary(t) and t != "" ->
          Map.put(fulfillment, "tracking_info", %{"number" => t})
        _ ->
          fulfillment
      end

    [json: %{"fulfillment" => fulfillment}]
  end

  # ─── customer.find — GET search ───────────────────────────────────────

  defp customer_find_request(args, _ctx) do
    params =
      %{"limit" => Map.get(args, "limit", 10)}
      |> maybe_put_kv("query", Map.get(args, "query"))

    [params: params]
  end

  defp customer_find_response(s, body) when s in 200..299 do
    customers =
      Map.get(body, "customers", [])
      |> Enum.map(&normalise_customer/1)

    {:ok, %{"customers" => customers}}
  end

  defp normalise_customer(c) do
    name = [c["first_name"], c["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> String.trim()

    %{
      "id"    => to_string(c["id"]),
      "name"  => if(name == "", do: nil, else: name),
      "email" => c["email"]
    }
  end

  # ─── customer.create — POST create ────────────────────────────────────

  defp customer_create_request(args, _ctx) do
    customer =
      %{"email" => args["email"]}
      |> maybe_put_kv("first_name", Map.get(args, "first_name"))
      |> maybe_put_kv("last_name",  Map.get(args, "last_name"))

    [json: %{"customer" => customer}]
  end

  # ─── inventory.adjust — POST adjust ───────────────────────────────────

  defp inventory_adjust_request(args, _ctx) do
    [
      json: %{
        "inventory_item_id"    => args["inventory_item_id"],
        "location_id"          => args["location_id"],
        "available_adjustment" => args["available_adjustment"]
      }
    ]
  end

  # ─── draft_order.create — POST create ─────────────────────────────────

  defp draft_order_create_request(args, _ctx) do
    draft =
      %{"line_items" => Map.get(args, "line_items", [])}

    draft =
      case Map.get(args, "customer_id") do
        cid when is_binary(cid) and cid != "" ->
          Map.put(draft, "customer", %{"id" => cid})
        _ ->
          draft
      end

    [json: %{"draft_order" => draft}]
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  defp with_bearer(opts, %{bearer_token: t}) when is_binary(t) and t != "" do
    headers = Keyword.get(opts, :headers, [])
    Keyword.put(opts, :headers, [{"x-shopify-access-token", t} | headers])
  end
  defp with_bearer(opts, _), do: opts

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
