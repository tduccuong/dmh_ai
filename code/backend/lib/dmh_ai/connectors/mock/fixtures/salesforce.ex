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
      "lead.find"           => &lead_find/1,
      "lead.create"         => &lead_create/1,
      "lead.update"         => &lead_update/1,
      "contact.find"        => &contact_find/1,
      "contact.create"      => &contact_create/1,
      "account.find"        => &account_find/1,
      "account.create"      => &account_create/1,
      "opportunity.find"    => &opportunity_find/1,
      "opportunity.create"  => &opportunity_create/1,
      "opportunity.update"  => &opportunity_update/1,
      "case.find"           => &case_find/1,
      "case.create"         => &case_create/1,
      "case.update"         => &case_update/1,
      "task.find"           => &task_find/1,
      "task.create"         => &task_create/1,
      "task.update"         => &task_update/1,
      "owner.find_by_email" => &owner_find_by_email/1,
      "report.run"          => &report_run/1,
      "note.create"         => &note_create/1
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
      case_id:         "500MOCKCASE01",
      case_subject:    "Verspätete Lieferung Rahmenvertrag",
      task_id:         "00TMOCKTASK01",
      task_subject:    "Rückruf Beispiel Vertrieb GmbH",
      note_id:         "002MOCKNOTE01",
      report_id:       "00OMOCKREPRT0",
      report_name:     "Quartalsumsatz DACH KMU",
      owner_id:        "005MOCKUSER01",
      owner_name:      "Anna Beispielvertrieb",
      owner_email:     "owner.mock@example.de"
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

  defp case_find(_args) do
    %{case_id: id, case_subject: subject, account_id: acct, owner_id: owner} = sentinels()

    %{
      "cases" => [
        %{
          "id"           => id,
          "subject"      => subject,
          "status"       => "Working",
          "priority"     => "High",
          "created_date" => "2026-05-10T08:30:00.000+0000",
          "owner_id"     => owner,
          "account_id"   => acct
        }
      ]
    }
  end

  defp case_create(_args) do
    %{case_id: id} = sentinels()

    %{
      "case_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp case_update(args) do
    %{
      "case_id" => Map.get(args, "case_id"),
      "updated" => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp lead_update(args) do
    %{
      "lead_id" => Map.get(args, "lead_id"),
      "updated" => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp task_find(_args) do
    %{task_id: id, task_subject: subject, owner_id: owner, opportunity_id: parent} = sentinels()

    %{
      "tasks" => [
        %{
          "id"            => id,
          "subject"       => subject,
          "status"        => "Not Started",
          "priority"      => "Normal",
          "activity_date" => "2026-06-03",
          "owner_id"      => owner,
          "record_id"     => parent
        }
      ]
    }
  end

  defp task_create(_args) do
    %{task_id: id} = sentinels()

    %{
      "task_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp task_update(args) do
    %{
      "task_id" => Map.get(args, "task_id"),
      "updated" => Map.keys(Map.get(args, "patch") || %{})
    }
  end

  defp owner_find_by_email(args) do
    %{owner_id: id, owner_name: name, owner_email: default_email} = sentinels()

    %{
      "owner" => %{
        "Id"    => id,
        "Name"  => name,
        "Email" => Map.get(args, "email") || default_email
      }
    }
  end

  defp report_run(_args) do
    %{report_id: id, report_name: name} = sentinels()

    %{
      "report" => %{
        "attributes" => %{
          "type" => "Report",
          "reportId" => id,
          "reportName" => name
        },
        "factMap" => %{
          "T!T" => %{
            "aggregates" => [%{"label" => "149.700,00 €", "value" => 149_700}],
            "rows" => []
          }
        }
      }
    }
  end

  defp note_create(_args) do
    %{note_id: id} = sentinels()

    %{
      "note_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end
end
