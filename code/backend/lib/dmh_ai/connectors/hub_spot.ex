# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.HubSpot do
  @moduledoc """
  HubSpot connector (Universal Region, Case B — vendor MCP).

  Six functions at the SME-relevant slice of HubSpot's CRM API. The
  vendor hosts an official MCP server at
  `developers.hubspot.com/mcp` (per the 2025 announcement) — we
  point `mcp_catalog` at that URL and let `MCPAdapter.Caller`
  bridge the call through the existing MCP plumbing.

  Vendor-specific error quirks live in `remap_error/1` — notably
  HubSpot's `409 + body.category="OBJECT_ALREADY_EXISTS"` for
  duplicate contacts/deals, which we surface as the canonical
  `:duplicate`.
  """

  use DmhAi.Connectors.MCPAdapter
  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl true
  def mcp_slug, do: "hubspot"

  @impl true
  def manifest do
    %Manifest{
      connector: "hubspot",
      region:    "universal",
      functions: %{
        "contact.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string, required: true}
          },
          returns: %{contacts: :list},
          scopes:  ["crm.objects.contacts.read"]
        },
        "contact.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "email" => %{type: :string, required: true, format: :email},
            "name"  => %{type: :string, required: false}
          },
          returns: %{contact_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["crm.objects.contacts.write"]
        },
        "deal.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "stage" => %{type: :string, required: false},
            "owner" => %{type: :string, required: false}
          },
          returns: %{deals: :list},
          scopes:  ["crm.objects.deals.read"]
        },
        "deal.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "contact_id" => %{type: :string, required: true},
            "amount"     => %{type: :number, required: true},
            "stage"      => %{type: :string, required: false},
            "name"       => %{type: :string, required: false}
          },
          returns: %{deal_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["crm.objects.deals.write"]
        },
        "deal.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "deal_id" => %{type: :string, required: true},
            "patch"   => %{type: :map,    required: true}
          },
          returns: %{deal_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["crm.objects.deals.write"]
        },
        "activity.log" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "deal_id" => %{type: :string, required: true},
            "kind"    => %{type: :string, required: true},
            "body"    => %{type: :string, required: true}
          },
          returns: %{activity_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["crm.objects.deals.write"]
        }
      }
    }
  end

  @impl true
  # HubSpot returns a JSON error body with `category` on conflicts;
  # `OBJECT_ALREADY_EXISTS` is the duplicate signal across both the
  # CRM v3 API and the hosted MCP. Map it to canonical `:duplicate`
  # so recipes / tasks branch deterministically rather than parsing
  # the upstream string.
  def remap_error(%{"category" => "OBJECT_ALREADY_EXISTS"}), do: :duplicate
  def remap_error({:http, 409, body}) when is_binary(body) do
    if body =~ "OBJECT_ALREADY_EXISTS", do: :duplicate, else: :passthrough
  end
  def remap_error(_), do: :passthrough
end
