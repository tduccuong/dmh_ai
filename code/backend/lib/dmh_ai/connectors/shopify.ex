# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Shopify do
  @moduledoc """
  Shopify connector (Universal Region, Case B — vendor MCP).

  Seventeen functions at the SME-relevant slice of Shopify's Admin
  API (shopify.dev/docs/api/admin-rest) — products, orders,
  customers, inventory, marketing:

    product.find             [read]   search the product catalogue
    product.create           [write]  create a product
    product.update           [write]  PUT-patch an existing product
    product.delete           [write]  delete a product
    order.find               [read]   list orders (filter by status)
    order.fulfill            [write]  fulfil an order (optional tracking)
    order.cancel             [write]  cancel an order (optional reason / email)
    order.refund             [write]  refund an order against its primary payment
    transaction.find         [read]   list transactions for one order
    customer.find            [read]   search customers
    customer.create          [write]  create a customer by email
    customer.update          [write]  PUT-patch an existing customer
    inventory.adjust         [write]  adjust an inventory level at a location (delta)
    inventory.set_level      [write]  set an inventory level at a location (absolute)
    draft_order.create       [write]  open a draft order (cart/quote)
    discount.create          [write]  create a price rule + attached discount code
    abandoned_checkout.find  [read]   list abandoned checkouts

  Five capability groups (products / orders / customers / inventory
  / marketing) so admins can scope per-org — a fulfilment-only org
  might tick orders + inventory, while a full storefront org enables
  all five.

  ## Vendor quirks (`remap_error/1`)

  Shopify returns HTTP 422 with a per-field `errors` map on
  uniqueness conflicts; the phrase "has already been taken" is the
  duplicate signal. Map it to canonical `:duplicate` so recipes /
  tasks branch deterministically rather than parsing the upstream
  string.

  ## Two-step caveat: `discount.create`

  Shopify ties discount codes to a *price rule*. There is no single
  endpoint that creates both. `discount.create` issues TWO calls:
  first `POST /price_rules.json` to mint the rule, then `POST
  /price_rules/{id}/discount_codes.json` to attach the code. If
  step 2 fails, step 1 leaves an orphan price rule on the shop — the
  shim does not auto-roll-back. Operators handling a failed
  `discount.create` should delete the dangling rule manually via
  the Shopify admin UI.

  ## Refund without line items: `order.refund`

  Shopify refunds are tied to transactions, not orders. The simplest
  refund path posts a refund with an empty `refund_line_items` list
  and a single `refund` transaction against the order's primary
  payment for the supplied amount. This refunds money without
  itemising which line items are being credited — fine for the
  common "refund the whole charge" case, but unsuitable for partial
  per-line refunds. For per-line refunds, callers must compose the
  refund payload directly against the REST API.

  ## REST → GraphQL migration risk

  This connector targets the 2024-01 REST Admin API. Shopify has
  publicly stated that REST is on a deprecation path in favour of
  the GraphQL Admin API (gid-based identifiers, different envelope
  shapes, different error model). When that deprecation lands every
  function in this module will need a parallel GraphQL handler;
  the shape of `args` + `returns` should remain stable but the
  internal request / response transforms will be rewritten.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  # Shopify's Admin API is versioned + per-shop: every call lives at
  # `https://{shop}.myshopify.com/admin/api/<version>/...`. `{shop}`
  # is a placeholder, not a real host — the framework must template
  # it per-shop from the connecting user's credential before any live
  # call. The mock path never substitutes it (the fixture server
  # answers by function name, not URL).
  @api_base "https://{shop}.myshopify.com/admin/api/2024-01"

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(access_token) when is_binary(access_token) do
    # Shopify has no OIDC userinfo endpoint. The connecting shop's
    # email + numeric id come from the Admin `shop.json` resource,
    # read with the access token in the `X-Shopify-Access-Token`
    # header. Response: `{"shop": {"email": ..., "id": ..., ...}}`.
    url = @api_base <> "/shop.json"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: %{"shop" => %{"email" => email, "id" => id}}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email, id: to_string(id)}}

      {:ok, %{status: 200, body: %{"shop" => %{"email" => email}}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email}}

      {:ok, %{status: s, body: body}} ->
        {:error, {:http, s, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp http_get(url, access_token) do
    case Application.get_env(:dmh_ai, :__shopify_shop_stub__) do
      nil ->
        Req.get(url,
          headers: [{"x-shopify-access-token", access_token}],
          finch: DmhAi.Finch,
          receive_timeout: 5_000,
          retry: false
        )

      stub ->
        stub.(url, access_token)
    end
  end

  @impl true
  def mcp_slug, do: "shopify"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://shopify.dev/docs/api/admin-rest", title: "Shopify Admin API overview"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/product", title: "Shopify Admin — Products"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/order", title: "Shopify Admin — Orders"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/customer", title: "Shopify Admin — Customers"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/inventorylevel", title: "Shopify Admin — Inventory"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/refund", title: "Shopify Admin — Refunds"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/transaction", title: "Shopify Admin — Transactions"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/pricerule", title: "Shopify Admin — Price Rules"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/discountcode", title: "Shopify Admin — Discount Codes"},
       %{url: "https://shopify.dev/docs/api/admin-rest/2024-01/resources/checkout", title: "Shopify Admin — Checkouts (abandoned)"}
     ]}
  end

  # Per-user metadata sweep. Shopify exposes no property-schema
  # endpoint analogous to HubSpot's `/crm/v3/properties/<object>` —
  # its resources are fixed-shape, not user-extensible with custom
  # properties. So there is nothing to sweep: when the user has a
  # credential we return an empty row set (no metadata to cache),
  # and when they don't we surface the missing-credential error so
  # the runner's indicator turns red — same contract as the other
  # connectors.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    case DmhAi.Auth.Credentials.lookup_all(user_id, "oauth:shopify") do
      [%{payload: %{"access_token" => token}} | _] when is_binary(token) ->
        {:ok, []}

      _ ->
        {:error, :no_shopify_credential}
    end
  end

  # Layer B reader. Shopify resources are fixed-shape with no custom
  # property schema to introspect, so there is no metadata cache to
  # consult. Always return `:not_supported`, which the compiler
  # treats as "trust the literal" — same contract as the default.
  @impl true
  def inspect_property(_function_name, _path, _ctx), do: {:error, :not_supported}

  @impl true
  def manifest do
    %Manifest{
      connector: "shopify",
      region:    "universal",
      functions: %{
        # vendor: GET /admin/api/2024-01/products.json
        # docs:   https://shopify.dev/docs/api/admin-rest/2024-01/resources/product
        "product.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            # Workflow authors legitimately bake search strings
            # ("all hoodies") OR bind them to trigger inputs
            # (`{{T.query}}`). Either form is fine — the validator
            # accepts both under `:literal_default`.
            "query" => %{type: :string,  required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{products: :list},
          scopes:  ["read_products"]
        },

        # vendor: POST /admin/api/2024-01/products.json
        "product.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "title"     => %{type: :string, required: true,
                             provenance: %{kind: :from_user}},
            "body_html" => %{type: :string, required: false},
            "vendor"    => %{type: :string, required: false},
            "price"     => %{type: :number, required: false}
          },
          returns: %{product_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["write_products"]
        },

        # vendor: PUT /admin/api/2024-01/products/{id}.json
        # The agent uses this for post-call "set the price to 29.90"
        # / "change the vendor" follow-ups. `patch` is a free-form
        # map of Shopify product fields → values; the shim does not
        # enumerate or validate field names so any field passes
        # through.
        "product.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "product_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "shopify.product.find"}},
            "patch"      => %{type: :map,    required: true,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{product_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write_products"]
        },

        # vendor: GET /admin/api/2024-01/orders.json
        # docs:   https://shopify.dev/docs/api/admin-rest/2024-01/resources/order
        "order.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "status" => %{type: :string,  required: false},
            "limit"  => %{type: :integer, required: false}
          },
          returns: %{orders: :list},
          scopes:  ["read_orders"]
        },

        # vendor: POST /admin/api/2024-01/fulfillments.json
        # shim translation: `order_id` → fulfilment's line-item
        # scope; `tracking_number` → tracking_info.
        "order.fulfill" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "order_id"        => %{type: :string, required: true,
                                   provenance: %{kind: :lookup,
                                                 source: "shopify.order.find"}},
            "tracking_number" => %{type: :string, required: false}
          },
          returns: %{fulfillment_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write_orders"]
        },

        # vendor: GET /admin/api/2024-01/customers/search.json
        "customer.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{customers: :list},
          scopes:  ["read_customers"]
        },

        # vendor: POST /admin/api/2024-01/customers.json
        "customer.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "email"      => %{type: :string, required: true, format: :email,
                              provenance: %{kind: :from_user}},
            "first_name" => %{type: :string, required: false},
            "last_name"  => %{type: :string, required: false}
          },
          returns: %{customer_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["write_customers"]
        },

        # vendor: POST /admin/api/2024-01/inventory_levels/adjust.json
        "inventory.adjust" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "inventory_item_id"    => %{type: :string,  required: true,
                                        provenance: %{kind: :lookup,
                                                      source: "shopify.product.find"}},
            "location_id"          => %{type: :string,  required: true,
                                        provenance: %{kind: :from_user}},
            "available_adjustment" => %{type: :integer, required: true,
                                        provenance: %{kind: :from_user}}
          },
          returns: %{inventory_level: :map},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write_inventory"]
        },

        # vendor: POST /admin/api/2024-01/draft_orders.json
        # Draft orders are carts/quotes a merchant builds for a
        # customer before invoicing; `line_items` is the required
        # cart body, `customer_id` optionally attaches a customer.
        "draft_order.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "customer_id" => %{type: :string, required: false},
            "line_items"  => %{type: :list,   required: true,
                               provenance: %{kind: :literal_default}}
          },
          returns: %{draft_order_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["write_draft_orders"]
        },

        # vendor: DELETE /admin/api/2024-01/products/{product_id}.json
        "product.delete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "product_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "shopify.product.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write_products"]
        },

        # vendor: POST /admin/api/2024-01/orders/{order_id}/cancel.json
        # `email_customer` maps to the upstream `email` boolean — when
        # true Shopify sends the cancellation notice to the buyer.
        "order.cancel" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "order_id"       => %{type: :string,  required: true,
                                  provenance: %{kind: :lookup,
                                                source: "shopify.order.find"}},
            "reason"         => %{type: :string,  required: false,
                                  provenance: %{kind: :literal_default,
                                                value: "customer"}},
            "email_customer" => %{type: :boolean, required: false}
          },
          returns: %{order_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write_orders"]
        },

        # vendor: POST /admin/api/2024-01/orders/{order_id}/refunds.json
        # Shopify refunds bind to transactions, not orders. This shim
        # composes the simplest valid refund: an empty
        # `refund_line_items` list + a single `refund` transaction for
        # the supplied amount. See module doc — fine for "refund the
        # whole charge", not for partial per-line refunds.
        # `amount` is a string because Shopify money fields are
        # stringly-typed across the Admin API.
        "order.refund" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "order_id" => %{type: :string, required: true,
                            provenance: %{kind: :lookup,
                                          source: "shopify.order.find"}},
            "amount"   => %{type: :string, required: true,
                            provenance: %{kind: :from_user}},
            "currency" => %{type: :string, required: false,
                            provenance: %{kind: :literal_default,
                                          value: "EUR"}},
            "note"     => %{type: :string, required: false}
          },
          returns: %{refund_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write_orders"]
        },

        # vendor: POST /admin/api/2024-01/inventory_levels/set.json
        # Sibling of `inventory.adjust`. `adjust` is delta-based
        # ("+3 / -2"); `set_level` is absolute ("there are now 12"),
        # which is the right verb when the caller knows the final
        # stock count rather than the change.
        "inventory.set_level" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "inventory_item_id" => %{type: :string,  required: true,
                                     provenance: %{kind: :lookup,
                                                   source: "shopify.product.find"}},
            "location_id"       => %{type: :string,  required: true,
                                     provenance: %{kind: :from_user}},
            "available"         => %{type: :integer, required: true,
                                     provenance: %{kind: :from_user}}
          },
          returns: %{inventory_level: :map},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write_inventory"]
        },

        # vendor: PUT /admin/api/2024-01/customers/{customer_id}.json
        # `patch` is a free-form map of Shopify customer fields →
        # values; the shim does not enumerate or validate field names
        # so any field passes through.
        "customer.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "customer_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "shopify.customer.find"}},
            "patch"       => %{type: :map,    required: true,
                               provenance: %{kind: :literal_default}}
          },
          returns: %{customer_id: :string},
          errors:  [:unauthorised, :not_found, :duplicate, :rate_limited],
          scopes:  ["write_customers"]
        },

        # CUSTOM HANDLER — two API calls. See module doc for the
        # orphan-price-rule caveat when step 2 fails.
        # vendor: POST /admin/api/2024-01/price_rules.json
        #       + POST /admin/api/2024-01/price_rules/{id}/discount_codes.json
        # `value` is stringly-typed; Shopify expects negative values
        # for percentage / fixed_amount discounts (e.g. "-10.0" for
        # 10% off when `value_type` is "percentage").
        "discount.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "code"       => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "value_type" => %{type: :string, required: true,
                              provenance: %{kind: :literal_default,
                                            value: "percentage"}},
            "value"      => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "starts_at"  => %{type: :string, required: false,
                              provenance: %{kind: :literal_default}},
            "ends_at"    => %{type: :string, required: false}
          },
          returns: %{discount_code_id: :string, price_rule_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["write_price_rules", "write_discounts"]
        },

        # vendor: GET /admin/api/2024-01/checkouts.json
        # Shopify exposes abandoned checkouts via the generic
        # `/checkouts.json` listing — there is no separate
        # `/abandoned_checkouts.json` endpoint in 2024-01.
        "abandoned_checkout.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "since_id" => %{type: :string,  required: false},
            "limit"    => %{type: :integer, required: false}
          },
          returns: %{checkouts: :list},
          scopes:  ["read_checkouts"]
        },

        # vendor: GET /admin/api/2024-01/orders/{order_id}/transactions.json
        # Useful as a follow-up to `order.find` when the agent needs
        # the payment trail (gateway, kind, amount) — e.g. before
        # calling `order.refund` so it knows how much was charged.
        "transaction.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "order_id" => %{type: :string, required: true,
                            provenance: %{kind: :lookup,
                                          source: "shopify.order.find"}}
          },
          returns: %{transactions: :list},
          scopes:  ["read_orders"]
        }
      }
    }
  end

  @impl true
  # Shopify exposes /admin/api/2024-01/customers/search.json keyed by
  # email, but a dedicated identity-pivot function is not yet in this
  # manifest. Fix: add `customers.find_by_email` and switch this to:
  #   %{function: "shopify.customers.find_by_email",
  #     by_arg: :email, emit_field: "id"}
  def identity_lookup, do: nil

  @impl true
  def remap_error(%{"errors" => errors}) when is_map(errors) do
    flat =
      errors
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    if flat =~ "has already been taken", do: :duplicate, else: :passthrough
  end

  def remap_error({:http, 422, body}) when is_binary(body) do
    if body =~ "has already been taken", do: :duplicate, else: :passthrough
  end

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Shopify OAuth lives
  at `{shop}.myshopify.com/admin/oauth/authorize` (consent) +
  `{shop}.myshopify.com/admin/oauth/access_token` (exchange).

  IMPORTANT: Shopify OAuth is per-shop — `{shop}` is a placeholder,
  not a real host. The generic OAuth path must template `{shop}` from
  the shop domain the merchant supplies before redirecting; until that
  per-shop templating lands, live OAuth is not exercisable. The mock
  test does not drive the OAuth flow, so this descriptor is correct
  as a vendor-fact record while the per-shop substitution is wired.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "shopify",
      display_name:           "Shopify",
      host_match:             "myshopify.com",
      authorization_endpoint: "https://{shop}.myshopify.com/admin/oauth/authorize",
      token_endpoint:         "https://{shop}.myshopify.com/admin/oauth/access_token",
      scopes: [
        "read_products",
        "write_products",
        "read_orders",
        "write_orders",
        "read_customers",
        "write_customers",
        "write_inventory",
        "write_draft_orders",
        "read_checkouts",
        "write_price_rules",
        "write_discounts"
      ],
      # Shopify ships no OIDC userinfo endpoint; identity capture
      # lives in `fetch_userinfo/1` (see top of module) via the Admin
      # `shop.json` resource, which doesn't fit the OIDC Bearer-auth
      # pattern the catalog's generic userinfo fields assume.
      userinfo_endpoint:      nil,
      userinfo_field_path:    nil,
      extra_auth_params:      %{}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Admin sets `mcp_url`
  via External Connectors (pre-filled to the in-process default).
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "shopify",
      name:        "Shopify",
      description: "Shopify Admin — products, orders, customers, inventory.",
      auth_kind:   :oauth,
      categories:  ["ecommerce", "retail"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (German fake store +
  product / order IDs) so chain results are mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_shopify",
      port_env:     "DMH_AI_SHOPIFY_MOCK_PORT",
      default_port: 8090,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.Shopify.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the Shopify MCP as an in-process REST translator
  on the shared real-MCP port. FE pre-fills this in the External
  Connectors form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/shopify"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount Shopify on the
  shared in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.Shopify.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Five
  domain groups go live — products / orders / customers / inventory
  / marketing — so a fulfilment-only org can expose orders +
  inventory and skip the rest, while a full storefront org enables
  all five. The three enforcement layers (OAuth scope filter, tool
  catalog filter, dispatcher gate) all read from
  `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "products",
        display_name: "Products",
        description:  "Search, create, update, and delete storefront products.",
        scopes:       ["read_products", "write_products"],
        functions:    ["product.find", "product.create", "product.update", "product.delete"],
        vendor_prereq: %{
          label:      "Shopify app scopes (Products)",
          enable_url: "https://shopify.dev/docs/apps/auth/oauth"
        }
      },
      %{
        id:           "orders",
        display_name: "Orders",
        description:  "Find orders, fulfil / cancel / refund them, list transactions, and build draft orders.",
        scopes:       ["read_orders", "write_orders", "write_draft_orders"],
        functions:    [
          "order.find",
          "order.fulfill",
          "order.cancel",
          "order.refund",
          "transaction.find",
          "draft_order.create"
        ],
        vendor_prereq: %{
          label:      "Shopify app scopes (Orders)",
          enable_url: "https://shopify.dev/docs/apps/auth/oauth"
        }
      },
      %{
        id:           "customers",
        display_name: "Customers",
        description:  "Search, create, and update customer records.",
        scopes:       ["read_customers", "write_customers"],
        functions:    ["customer.find", "customer.create", "customer.update"],
        vendor_prereq: %{
          label:      "Shopify app scopes (Customers)",
          enable_url: "https://shopify.dev/docs/apps/auth/oauth"
        }
      },
      %{
        id:           "inventory",
        display_name: "Inventory",
        description:  "Adjust (delta) or set (absolute) inventory levels at a location.",
        scopes:       ["write_inventory"],
        functions:    ["inventory.adjust", "inventory.set_level"],
        vendor_prereq: %{
          label:      "Shopify app scopes (Inventory)",
          enable_url: "https://shopify.dev/docs/apps/auth/oauth"
        }
      },
      %{
        id:           "marketing",
        display_name: "Marketing",
        description:  "Create discount codes and review abandoned checkouts.",
        scopes:       ["read_checkouts", "write_price_rules", "write_discounts"],
        functions:    ["discount.create", "abandoned_checkout.find"],
        vendor_prereq: %{
          label:      "Shopify app scopes (Marketing)",
          enable_url: "https://shopify.dev/docs/apps/auth/oauth"
        }
      }
    ]
  end

end
