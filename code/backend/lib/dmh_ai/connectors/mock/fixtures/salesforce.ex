# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Salesforce do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Salesforce connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  Sentinel identifiers (German fake company + Salesforce-style object
  IDs) let runbooks + tests assert mechanically that the chain's
  output came from the connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "lead.find"          => &lead_find/1,
      "lead.create"        => &lead_create/1,
      "contact.find"       => &contact_find/1,
      "contact.create"     => &contact_create/1,
      "account.find"       => &account_find/1,
      "account.create"     => &account_create/1,
      "opportunity.find"   => &opportunity_find/1,
      "opportunity.create" => &opportunity_create/1,
      "opportunity.update" => &opportunity_update/1,
      "case.create"        => &case_create/1,
      "task.create"        => &task_create/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      company_name:    "Beispiel Vertrieb GmbH",
      lead_name:       "Lukas Beispielinteressent",
      lead_id:         "00QMOCKLEAD00001",
      contact_name:    "Klara Beispielkontakt",
      contact_email:   "klara.kontakt@beispiel-vertrieb-demo.example",
      contact_id:      "003MOCKCONT00001",
      account_id:      "001MOCKACCT00001",
      opportunity_name: "Beispiel Rahmenvertrag 2026",
      opportunity_id:  "006MOCKOPP000001",
      case_id:         "500MOCKCASE00001",
      task_id:         "00TMOCKTASK00001"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp lead_find(_args) do
    %{lead_id: id, lead_name: name, company_name: company} = sentinels()

    %{
      "leads" => [
        %{
          "id"      => id,
          "name"    => name,
          "company" => company,
          "email"   => nil,
          "status"  => "Open - Not Contacted"
        }
      ]
    }
  end

  defp lead_create(_args) do
    %{lead_id: id} = sentinels()

    %{
      "lead_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp contact_find(_args) do
    %{contact_id: id, contact_name: name, contact_email: email, account_id: acct} = sentinels()

    %{
      "contacts" => [
        %{
          "id"         => id,
          "name"       => name,
          "email"      => email,
          "account_id" => acct
        }
      ]
    }
  end

  defp contact_create(_args) do
    %{contact_id: id} = sentinels()

    %{
      "contact_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp account_find(_args) do
    %{account_id: id, company_name: name} = sentinels()

    %{
      "accounts" => [
        %{
          "id"       => id,
          "name"     => name,
          "website"  => "https://beispiel-vertrieb-demo.example",
          "industry" => "Manufacturing"
        }
      ]
    }
  end

  defp account_create(_args) do
    %{account_id: id} = sentinels()

    %{
      "account_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp opportunity_find(_args) do
    %{opportunity_id: id, opportunity_name: name, account_id: acct} = sentinels()

    %{
      "opportunities" => [
        %{
          "id"         => id,
          "name"       => name,
          "stage"      => "Proposal/Price Quote",
          "amount"     => 49_900,
          "close_date" => "2026-09-30",
          "account_id" => acct
        }
      ]
    }
  end

  defp opportunity_create(_args) do
    %{opportunity_id: id} = sentinels()

    %{
      "opportunity_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp opportunity_update(args) do
    %{
      "opportunity_id" => Map.get(args, "opportunity_id"),
      "updated"        => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp case_create(_args) do
    %{case_id: id} = sentinels()

    %{
      "case_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp task_create(_args) do
    %{task_id: id} = sentinels()

    %{
      "task_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end
end
