# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Stripe do
  @moduledoc """
  Stripe connector (Universal Region — payments). The first Case-B
  connector authenticated via **API key** rather than OAuth. The
  per-user credential row is `target='api_key:stripe'`, `kind='api_key'`
  with payload `{"api_key": "sk_..."}`.

  Fourteen functions at the SME-relevant slice — customers, payment
  intents, refunds, charges, products, prices, subscriptions, and
  invoices:

    customer.find          [read]   look up customers by query
    customer.create        [write]  create a new customer
    customer.update        [write]  update a customer's email / name / metadata
    payment_intent.create  [write]  start a payment
    refund.create          [write]  refund a charge
    charge.find            [read]   list charges (optionally per customer)
    subscription.find      [read]   list subscriptions
    subscription.create    [write]  create a subscription on a price
    subscription.cancel    [write]  cancel a subscription
    product.find           [read]   look up products / prices
    price.find             [read]   list prices (optionally per product)
    invoice.find           [read]   list invoices (optionally per customer + status)
    invoice.create         [write]  create a draft / auto-advancing invoice
    invoice.send           [write]  send an invoice email to the customer

  Stripe error contract (`/v1/...` REST):
    * 429              → `:rate_limited`.
    * 404              → `:not_found`.
    * 401              → `:unauthorised`.
    * `code: idempotency_key_in_use` → `:duplicate` (same idempotency
      key reused on a different request — Stripe's own dedup).

  ## Stripe form-encoded write bodies

  Stripe REST writes are `application/x-www-form-urlencoded`, not JSON.
  Nested collections use bracket-indexed keys — `subscription.create`
  ships a single price+quantity line item as
  `items[0][price]={price_id}&items[0][quantity]={quantity}`. The
  vendor-hosted MCP normalises that shape for us; the manifest declares
  the friendly `price_id` / `quantity` args and Stripe's MCP composes
  the form payload before hitting `/v1/subscriptions`.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl true
  def mcp_slug, do: "stripe"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://stripe.com/docs/api",          title: "Stripe API reference"},
       %{url: "https://stripe.com/docs/api/customers", title: "Stripe — Customers"},
       %{url: "https://stripe.com/docs/api/payment_intents", title: "Stripe — Payment Intents"},
       %{url: "https://stripe.com/docs/api/refunds",  title: "Stripe — Refunds"},
       %{url: "https://stripe.com/docs/api/subscriptions", title: "Stripe — Subscriptions"},
       %{url: "https://stripe.com/docs/api/charges",  title: "Stripe — Charges"},
       %{url: "https://stripe.com/docs/api/invoices", title: "Stripe — Invoices"},
       %{url: "https://stripe.com/docs/api/prices",   title: "Stripe — Prices"}
     ]}
  end

  @impl true
  def credential_kind, do: :api_key

  @impl true
  def manifest do
    %Manifest{
      connector: "stripe",
      region:    "universal",
      functions: %{
        "customer.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string, required: false, format: :email},
            "query" => %{type: :string, required: false}
          },
          returns: %{customers: :list}
        },
        "customer.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "email" => %{type: :string, required: true, format: :email,
                         provenance: %{kind: :from_user}},
            "name"  => %{type: :string, required: false}
          },
          returns: %{customer_id: :string},
          errors:  [:unauthorised, :rate_limited, :duplicate]
        },
        # vendor: POST /v1/customers/{customer_id}
        # Stripe treats `POST /v1/customers/{id}` as the update verb —
        # any field not in the form body is left untouched. Metadata is
        # a free-form `metadata[key]=value` map the operator can stamp
        # workflow-specific tags onto (e.g. `metadata[plan]=pro`).
        "customer.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "customer_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "stripe.customer.find"}},
            "email"       => %{type: :string, required: false, format: :email,
                               provenance: %{kind: :from_user}},
            "name"        => %{type: :string, required: false,
                               provenance: %{kind: :from_user}},
            "metadata"    => %{type: :map,    required: false,
                               provenance: %{kind: :literal_default}}
          },
          returns: %{customer_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited, :duplicate]
        },
        "payment_intent.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            # Amount is the cents/minor-unit value. Most workflows
            # bind it to a trigger input (`{{T.amount}}`), but a
            # subscription-style workflow legitimately bakes a
            # fixed value — `:literal_default` accepts both.
            "amount"      => %{type: :integer, required: true,
                               provenance: %{kind: :literal_default}},
            # Org-default currency. Stripe accounts have a default
            # but the API doesn't autofill — workflow author can
            # override at IR write time when the org operates in a
            # different currency.
            "currency"    => %{type: :string,  required: true,
                               provenance: %{kind: :literal_default, value: "EUR"}},
            "customer_id" => %{type: :string,  required: false}
          },
          returns: %{payment_intent_id: :string, client_secret: :string},
          errors:  [:unauthorised, :rate_limited, :duplicate]
        },
        "refund.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "charge_id" => %{type: :string,  required: true,
                             provenance: %{kind: :lookup,
                                           source: "stripe.charge.find"}},
            "amount"    => %{type: :integer, required: false},
            "reason"    => %{type: :string,  required: false}
          },
          returns: %{refund_id: :string},
          errors:  [:unauthorised, :not_found, :duplicate]
        },
        # vendor: GET /v1/charges?customer={customer_id}&limit={limit}
        # Lists charges across the account; the optional `customer_id`
        # narrows to one customer (Stripe's standard list filter). A
        # successful refund refers back to the charge id, so this
        # function feeds `refund.create`'s `charge_id` lookup.
        "charge.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "customer_id" => %{type: :string,  required: false},
            "limit"       => %{type: :integer, required: false}
          },
          returns: %{charges: :list}
        },
        "subscription.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "customer_id" => %{type: :string, required: false},
            "status"      => %{type: :string, required: false}
          },
          returns: %{subscriptions: :list}
        },
        # vendor: POST /v1/subscriptions
        # Form-encoded body — one price+quantity line item ships as
        # `items[0][price]={price_id}&items[0][quantity]={quantity}`;
        # Stripe's vendor-hosted MCP composes the bracket-indexed key
        # shape from the friendly `price_id` / `quantity` args.
        "subscription.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "customer_id" => %{type: :string,  required: true,
                               provenance: %{kind: :lookup,
                                             source: "stripe.customer.find"}},
            "price_id"    => %{type: :string,  required: true,
                               provenance: %{kind: :lookup,
                                             source: "stripe.price.find"}},
            "quantity"    => %{type: :integer, required: false,
                               provenance: %{kind: :literal_default, value: 1}}
          },
          returns: %{subscription_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited, :duplicate]
        },
        # vendor: DELETE /v1/subscriptions/{subscription_id}
        # Cancels at period end is a separate update; this verb is the
        # immediate cancel.
        "subscription.cancel" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "subscription_id" => %{type: :string, required: true,
                                   provenance: %{kind: :lookup,
                                                 source: "stripe.subscription.find"}}
          },
          returns: %{subscription_id: :string, status: :string},
          errors:  [:unauthorised, :not_found, :rate_limited]
        },
        "product.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: false},
            "active"=> %{type: :boolean, required: false}
          },
          returns: %{products: :list}
        },
        # vendor: GET /v1/prices?product={product_id}&active={active}&limit={limit}
        "price.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "product_id" => %{type: :string,  required: false,
                              provenance: %{kind: :lookup,
                                            source: "stripe.product.find"}},
            "active"     => %{type: :boolean, required: false},
            "limit"      => %{type: :integer, required: false}
          },
          returns: %{prices: :list}
        },
        # vendor: GET /v1/invoices?customer={customer_id}&status={status}&limit={limit}
        # `status` accepts Stripe's literal vocab — "open", "paid",
        # "draft", "uncollectible", "void".
        "invoice.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "customer_id" => %{type: :string,  required: false,
                               provenance: %{kind: :lookup,
                                             source: "stripe.customer.find"}},
            "status"      => %{type: :string,  required: false},
            "limit"       => %{type: :integer, required: false}
          },
          returns: %{invoices: :list}
        },
        # vendor: POST /v1/invoices
        # `auto_advance: true` (the manifest default) tells Stripe to
        # finalise + attempt collection automatically; flip it to
        # false to leave the invoice as a draft.
        "invoice.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "customer_id"  => %{type: :string,  required: true,
                                provenance: %{kind: :lookup,
                                              source: "stripe.customer.find"}},
            "auto_advance" => %{type: :boolean, required: false,
                                provenance: %{kind: :literal_default, value: true}},
            "description"  => %{type: :string,  required: false,
                                provenance: %{kind: :from_user}}
          },
          returns: %{invoice_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited, :duplicate]
        },
        # vendor: POST /v1/invoices/{invoice_id}/send
        # Triggers the customer-facing email; the invoice must already
        # be finalised (status `open`).
        "invoice.send" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "invoice_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "stripe.invoice.find"}}
          },
          returns: %{invoice_id: :string, status: :string},
          errors:  [:unauthorised, :not_found, :rate_limited]
        }
      }
    }
  end

  @impl true
  # Stripe REST errors:
  #   {"error": {"type": "...", "code": "...", "message": "...",
  #              "param": "...", "doc_url": "..."}}
  def remap_error(%{"error" => %{"code" => "idempotency_key_in_use"}}),
    do: :duplicate

  def remap_error(%{"error" => %{"code" => "resource_missing"}}), do: :not_found

  def remap_error(%{"error" => %{"type" => type}}) do
    case type do
      "rate_limit_error"        -> :rate_limited
      "authentication_error"    -> :unauthorised
      "invalid_request_error"   -> :passthrough
      _                         -> :passthrough
    end
  end

  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error(_), do: :passthrough
end
