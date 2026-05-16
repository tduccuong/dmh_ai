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

  Six functions at the SME-relevant slice:

    customer.find          [read]   look up customers by query
    customer.create        [write]  create a new customer
    payment_intent.create  [write]  start a payment
    refund.create          [write]  refund a charge
    subscription.find      [read]   list subscriptions
    product.find           [read]   look up products / prices

  Stripe error contract (`/v1/...` REST):
    * 429              → `:rate_limited`.
    * 404              → `:not_found`.
    * 401              → `:unauthorised`.
    * `code: idempotency_key_in_use` → `:duplicate` (same idempotency
      key reused on a different request — Stripe's own dedup).
  """

  use DmhAi.Connectors.MCPAdapter
  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl true
  def mcp_slug, do: "stripe"

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
            "email" => %{type: :string, required: true, format: :email},
            "name"  => %{type: :string, required: false}
          },
          returns: %{customer_id: :string},
          errors:  [:unauthorised, :rate_limited, :duplicate]
        },
        "payment_intent.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "amount"      => %{type: :integer, required: true},
            "currency"    => %{type: :string,  required: true},
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
            "charge_id" => %{type: :string,  required: true},
            "amount"    => %{type: :integer, required: false},
            "reason"    => %{type: :string,  required: false}
          },
          returns: %{refund_id: :string},
          errors:  [:unauthorised, :not_found, :duplicate]
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
        "product.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: false},
            "active"=> %{type: :boolean, required: false}
          },
          returns: %{products: :list}
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
