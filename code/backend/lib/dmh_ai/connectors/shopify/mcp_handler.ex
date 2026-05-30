# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Shopify.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Shopify connector consumed by the
  generic `Connectors.MCPServer`. Each function is a 1:1 mapping
  to a Shopify Admin REST endpoint at `{shop}.myshopify.com/admin/
  api/2024-01/*` (except `discount.create`, which is two calls —
  see below):

    product.find             — GET    /products.json
    product.create           — POST   /products.json
    product.update           — PUT    /products/{id}.json
    product.delete           — DELETE /products/{id}.json
    order.find               — GET    /orders.json
    order.fulfill            — POST   /fulfillments.json
    order.cancel             — POST   /orders/{id}/cancel.json
    order.refund             — POST   /orders/{id}/refunds.json
    transaction.find         — GET    /orders/{id}/transactions.json
    customer.find            — GET    /customers/search.json
    customer.create          — POST   /customers.json
    customer.update          — PUT    /customers/{id}.json
    inventory.adjust         — POST   /inventory_levels/adjust.json
    inventory.set_level      — POST   /inventory_levels/set.json
    draft_order.create       — POST   /draft_orders.json
    discount.create          — POST   /price_rules.json
                              + POST  /price_rules/{id}/discount_codes.json
    abandoned_checkout.find  — GET    /checkouts.json

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

  ## Path-param ids: `safe_path_id/1`

  Every numeric id reaching a URL path goes through
  `safe_path_id/1`, which whitelists Shopify's id charset
  (`^[A-Za-z0-9_-]+$`). An invalid value raises rather than
  interpolating, so the dispatcher surfaces an error envelope
  instead of building a request with an injected segment / query.

  ## Two-step: `discount.create`

  A price rule and its discount code are two Shopify objects on two
  endpoints. `discount.create` is a custom handler that issues a
  `POST /price_rules.json` first, then a `POST
  /price_rules/{price_rule_id}/discount_codes.json` second. If step
  2 fails the price rule from step 1 is left orphaned on the shop;
  the shim does not auto-roll-back (Shopify offers no transactional
  envelope around the two calls).

  ## Refund without line items: `order.refund`

  Shopify ties refunds to transactions, not orders. The shim posts
  the simplest valid refund — an empty `refund_line_items` list +
  one `refund` transaction for the supplied amount against the
  order's primary payment. Suitable for "refund the whole charge",
  not for partial per-line refunds.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  require Logger

  @api_base "https://{shop}.myshopify.com/admin/api/2024-01"

  # Shopify ids are numeric / numeric+suffix; the test fixtures also
  # carry slugified ids like `shopify_product_mock_001`. Whitelist
  # the union character set before any path interpolation.
  @path_id_re ~r/^[A-Za-z0-9_-]+$/

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
      },
      "product.delete" => %FunctionSpec{
        method:  :delete,
        url:     &product_delete_url/1,
        request: fn _args, _ctx -> [] end,
        response: &ok_true_response/2,
        doc:     "Delete a product."
      },
      "order.cancel" => %FunctionSpec{
        method:  :post,
        url:     &order_cancel_url/1,
        request: &order_cancel_request/2,
        response: &order_cancel_response/2,
        doc:     "Cancel an order with an optional reason / customer notification."
      },
      "order.refund" => %FunctionSpec{
        method:  :post,
        url:     &order_refund_url/1,
        request: &order_refund_request/2,
        response: &order_refund_response/2,
        doc:     "Refund an order against its primary payment (no line items)."
      },
      "transaction.find" => %FunctionSpec{
        method:  :get,
        url:     &transaction_find_url/1,
        response: &transaction_find_response/2,
        doc:     "List transactions for one order."
      },
      "customer.update" => %FunctionSpec{
        handler: &customer_update/2,
        doc:     "Patch customer fields (email, first_name, last_name, …)."
      },
      "inventory.set_level" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/inventory_levels/set.json",
        request: &inventory_set_level_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"inventory_level" => Map.get(body, "inventory_level", %{})}}
                  end,
        doc:     "Set an inventory level at a location (absolute, not delta)."
      },
      "discount.create" => %FunctionSpec{
        handler: &discount_create/2,
        doc:     "Create a price rule + attached discount code (two API calls)."
      },
      "abandoned_checkout.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/checkouts.json",
        request: &abandoned_checkout_find_request/2,
        response: &abandoned_checkout_find_response/2,
        doc:     "List abandoned checkouts."
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
    url   = "#{@api_base}/products/#{safe_path_id(args["product_id"])}.json"
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

  # ─── product.delete — DELETE /products/{id}.json ──────────────────────

  defp product_delete_url(args),
    do: "#{@api_base}/products/#{safe_path_id(args["product_id"])}.json"

  # ─── order.cancel — POST /orders/{id}/cancel.json ─────────────────────

  defp order_cancel_url(args),
    do: "#{@api_base}/orders/#{safe_path_id(args["order_id"])}/cancel.json"

  defp order_cancel_request(args, _ctx) do
    body =
      %{}
      |> maybe_put_kv("reason", Map.get(args, "reason"))
      |> maybe_put_kv("email",  Map.get(args, "email_customer"))

    [json: body]
  end

  defp order_cancel_response(s, body) when s in 200..299 do
    id =
      get_in(body, ["order", "id"]) ||
        Map.get(body, "id") ||
        Map.get(body, "order_id")

    {:ok, %{"order_id" => to_string(id || "")}}
  end

  # ─── order.refund — POST /orders/{id}/refunds.json ────────────────────

  defp order_refund_url(args),
    do: "#{@api_base}/orders/#{safe_path_id(args["order_id"])}/refunds.json"

  # Shopify refunds bind to transactions, not orders. Compose the
  # simplest valid refund: empty `refund_line_items` + one `refund`
  # transaction for the supplied amount + currency. See module doc.
  defp order_refund_request(args, _ctx) do
    refund =
      %{
        "refund_line_items" => [],
        "transactions" => [
          %{
            "kind"     => "refund",
            "amount"   => args["amount"],
            "currency" => Map.get(args, "currency", "EUR")
          }
        ]
      }
      |> maybe_put_kv("note", Map.get(args, "note"))

    [json: %{"refund" => refund}]
  end

  defp order_refund_response(s, body) when s in 200..299 do
    {:ok, %{"refund_id" => to_string(get_in(body, ["refund", "id"]) || "")}}
  end

  # ─── transaction.find — GET /orders/{id}/transactions.json ────────────

  defp transaction_find_url(args),
    do: "#{@api_base}/orders/#{safe_path_id(args["order_id"])}/transactions.json"

  defp transaction_find_response(s, body) when s in 200..299 do
    {:ok, %{"transactions" => Map.get(body, "transactions", [])}}
  end

  # ─── customer.update — PUT /customers/{id}.json ───────────────────────

  defp customer_update(args, ctx) do
    patch = args["patch"] || %{}
    url   = "#{@api_base}/customers/#{safe_path_id(args["customer_id"])}.json"
    opts  = [url: url, json: %{"customer" => patch}]

    case RestBridge.raw_request(:put, with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {:ok,
         %{
           "customer_id" =>
             to_string(get_in(body, ["customer", "id"]) || args["customer_id"]),
           "updated"     => Map.keys(patch)
         }}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  # ─── inventory.set_level — POST /inventory_levels/set.json ────────────

  defp inventory_set_level_request(args, _ctx) do
    [
      json: %{
        "inventory_item_id" => args["inventory_item_id"],
        "location_id"       => args["location_id"],
        "available"         => args["available"]
      }
    ]
  end

  # ─── discount.create — custom 2-step handler ──────────────────────────

  # 1) POST /price_rules.json — mint the price rule (carries the
  #    discount amount + value_type + activity window).
  # 2) POST /price_rules/{price_rule_id}/discount_codes.json — attach
  #    the human-readable code so customers can apply it at checkout.
  #
  # If step 2 fails the price rule created in step 1 is left orphaned
  # on the shop. The shim does not roll back; operators must clean up
  # via the Shopify admin UI.
  defp discount_create(args, ctx) do
    code        = args["code"]
    value_type  = Map.get(args, "value_type", "percentage")
    value       = args["value"]
    starts_at   = Map.get(args, "starts_at") || iso_now()
    ends_at     = Map.get(args, "ends_at")

    price_rule_body =
      %{
        "title"                     => code,
        "target_type"               => "line_item",
        "target_selection"          => "all",
        "allocation_method"         => "across",
        "value_type"                => value_type,
        "value"                     => value,
        "customer_selection"        => "all",
        "starts_at"                 => starts_at
      }
      |> maybe_put_kv("ends_at", ends_at)

    rule_url = "#{@api_base}/price_rules.json"
    rule_opts = [url: rule_url, json: %{"price_rule" => price_rule_body}]

    case RestBridge.raw_request(:post, with_bearer(rule_opts, ctx)) do
      {:ok, s1, body1} when s1 in 200..299 ->
        price_rule_id = to_string(get_in(body1, ["price_rule", "id"]) || "")
        attach_discount_code(price_rule_id, code, ctx)

      {:ok, status, body} ->
        {:error, DmhAi.Connectors.MCPServer.ErrorMap.classify(status, body)}

      {:error, _} = err ->
        err
    end
  end

  defp attach_discount_code("", _code, _ctx), do: {:error, :upstream_other}

  defp attach_discount_code(price_rule_id, code, ctx) do
    code_url =
      "#{@api_base}/price_rules/#{safe_path_id(price_rule_id)}/discount_codes.json"

    code_opts = [url: code_url, json: %{"discount_code" => %{"code" => code}}]

    case RestBridge.raw_request(:post, with_bearer(code_opts, ctx)) do
      {:ok, s2, body2} when s2 in 200..299 ->
        {:ok,
         %{
           "price_rule_id"    => price_rule_id,
           "discount_code_id" =>
             to_string(get_in(body2, ["discount_code", "id"]) || "")
         }}

      {:ok, status, body} ->
        # Step 2 failed — step 1's price rule is orphaned on the shop.
        # See module doc; the shim does not auto-roll-back.
        {:error, DmhAi.Connectors.MCPServer.ErrorMap.classify(status, body)}

      {:error, _} = err ->
        err
    end
  end

  # ─── abandoned_checkout.find — GET /checkouts.json ────────────────────

  defp abandoned_checkout_find_request(args, _ctx) do
    params =
      %{}
      |> maybe_put_kv("since_id", Map.get(args, "since_id"))
      |> maybe_put_kv("limit",    Map.get(args, "limit"))

    [params: params]
  end

  defp abandoned_checkout_find_response(s, body) when s in 200..299 do
    {:ok, %{"checkouts" => Map.get(body, "checkouts", [])}}
  end

  # ─── shared 2xx → `{ok: true}` response (delete-style) ───────────────

  defp ok_true_response(s, _body) when s in 200..299, do: {:ok, %{"ok" => true}}

  # ─── helpers ──────────────────────────────────────────────────────────

  defp with_bearer(opts, %{bearer_token: t}) when is_binary(t) and t != "" do
    headers = Keyword.get(opts, :headers, [])
    Keyword.put(opts, :headers, [{"x-shopify-access-token", t} | headers])
  end
  defp with_bearer(opts, _), do: opts

  # Whitelist a path-param id to the Shopify id charset before
  # interpolating it into a URL. A value that doesn't match raises —
  # the dispatcher surfaces it as an error envelope rather than
  # building a URL with an injected segment / query string.
  defp safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid shopify id: #{inspect(id)}"
    end
  end

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
