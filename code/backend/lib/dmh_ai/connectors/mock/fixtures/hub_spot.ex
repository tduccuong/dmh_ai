# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.HubSpot do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the HubSpot connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  Sentinel identifiers (German fake personas + deal IDs) let
  runbooks + tests assert mechanically that the chain's output
  came from the connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "contact.find"   => &contact_find/1,
      "contact.create" => &contact_create/1,
      "contact.update" => &contact_update/1,
      "company.find"   => &company_find/1,
      "company.create" => &company_create/1,
      "company.update" => &company_update/1,
      "deal.find"      => &deal_find/1,
      "deal.create"    => &deal_create/1,
      "deal.update"    => &deal_update/1,
      "activity.log"   => &activity_log/1,
      "task.create"    => &task_create/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      contact_name:  "Klara Vertriebsbeispiel",
      contact_email: "klara.vertrieb@dmh-hubspot-demo.example",
      contact_id:    "hs_contact_mock_001",
      company_name:  "Mustermann GmbH",
      company_domain: "mustermann-gmbh.example",
      company_id:    "hs_company_mock_004",
      deal_name:     "Mustermann GmbH — Q2 Stiftungsfeier",
      deal_id:       "hs_deal_mock_002",
      deal_stage:    "appointmentscheduled",
      deal_amount:   "15000",
      activity_id:   "hs_activity_mock_003",
      task_id:       "hs_task_mock_005"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp contact_find(_args) do
    %{contact_name: name, contact_email: email, contact_id: id} = sentinels()

    %{
      "contacts" => [
        %{
          "id"      => id,
          "name"    => name,
          "email"   => email,
          "company" => "Mustermann GmbH"
        }
      ]
    }
  end

  defp contact_create(args) do
    %{contact_id: id} = sentinels()

    %{
      "contact_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "email"      => Map.get(args, "email")
    }
  end

  defp deal_find(_args) do
    %{deal_id: id, deal_name: name, deal_stage: stage, deal_amount: amount} = sentinels()

    %{
      "deals" => [
        %{
          "id"          => id,
          "name"        => name,
          "amount"      => amount,
          "stage"       => stage,
          "close_date"  => "2026-06-30",
          "owner_id"    => "hs_owner_mock_001"
        }
      ]
    }
  end

  defp deal_create(args) do
    %{deal_id: id} = sentinels()

    %{
      "deal_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "name"    => Map.get(args, "name", "Untitled deal")
    }
  end

  defp deal_update(args) do
    %{
      "deal_id" => Map.get(args, "deal_id"),
      "updated" => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp activity_log(_args) do
    %{activity_id: id} = sentinels()

    %{
      "activity_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp contact_update(args) do
    %{
      "contact_id" => Map.get(args, "contact_id"),
      "updated"    => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp company_find(_args) do
    %{company_id: id, company_name: name, company_domain: domain} = sentinels()

    %{
      "companies" => [
        %{
          "id"       => id,
          "name"     => name,
          "domain"   => domain,
          "city"     => "Berlin",
          "country"  => "DE",
          "industry" => "Manufacturing"
        }
      ]
    }
  end

  defp company_create(args) do
    %{company_id: id} = sentinels()

    %{
      "company_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "name"       => Map.get(args, "name", "Untitled company")
    }
  end

  defp company_update(args) do
    %{
      "company_id" => Map.get(args, "company_id"),
      "updated"    => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp task_create(_args) do
    %{task_id: id} = sentinels()

    %{
      "task_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end
end
