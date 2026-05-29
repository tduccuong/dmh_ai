# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.DocuSign do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the DocuSign connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  The values returned here are the connector's *mapped* shapes (post
  `MCPHandler` translation), so a runbook / test asserts on the
  canonical keys (`envelopes`, `envelope_id`, `templates`,
  `recipient_id_added`, `envelope`), not DocuSign's raw envelopes.

  Sentinel identifiers (obviously-fake DocuSign UUID-shaped envelope
  / recipient / template ids + a fake envelope subject) let runbooks
  + tests assert mechanically that the chain's output came from the
  connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "envelope.find"   => &envelope_find/1,
      "envelope.create" => &envelope_create/1,
      "envelope.get"    => &envelope_get/1,
      "envelope.send"   => &envelope_send/1,
      "envelope.void"   => &envelope_void/1,
      "recipient.add"   => &recipient_add/1,
      "template.find"   => &template_find/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      envelope_id:      "11111111-mock-envl-0000-000000000001",
      envelope_subject: "Beispiel Mock-Vertrag zur Unterschrift",
      envelope_status:  "sent",
      recipient_id:     "22222222-mock-rcpt-0000-000000000001",
      template_id:      "33333333-mock-tmpl-0000-000000000001",
      template_name:    "Beispiel Mock-Vorlage"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp envelope_find(_args) do
    %{
      envelope_id:      id,
      envelope_subject: subject,
      envelope_status:  status
    } = sentinels()

    %{
      "envelopes" => [
        %{
          "envelope_id"   => id,
          "status"        => status,
          "email_subject" => subject
        }
      ]
    }
  end

  defp envelope_create(_args) do
    %{envelope_id: id} = sentinels()

    %{
      "envelope_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp envelope_get(_args) do
    %{
      envelope_id:      id,
      envelope_subject: subject,
      envelope_status:  status
    } = sentinels()

    %{
      "envelope" => %{
        "envelope_id"   => id,
        "status"        => status,
        "email_subject" => subject
      }
    }
  end

  defp envelope_send(_args) do
    %{"ok" => true}
  end

  defp envelope_void(_args) do
    %{"ok" => true}
  end

  defp recipient_add(_args) do
    %{recipient_id: id} = sentinels()

    %{
      "recipient_id_added" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp template_find(_args) do
    %{template_id: id, template_name: name} = sentinels()

    %{
      "templates" => [
        %{
          "template_id" => id,
          "name"        => name
        }
      ]
    }
  end
end
