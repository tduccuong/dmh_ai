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
      "envelope.find"                 => &envelope_find/1,
      "envelope.create"               => &envelope_create/1,
      "envelope.get"                  => &envelope_get/1,
      "envelope.send"                 => &envelope_send/1,
      "envelope.void"                 => &envelope_void/1,
      "envelope.list_recipients"      => &envelope_list_recipients/1,
      "envelope.list_documents"       => &envelope_list_documents/1,
      "envelope.download_document"    => &envelope_download_document/1,
      "envelope.create_from_template" => &envelope_create_from_template/1,
      "envelope.resend"               => &envelope_resend/1,
      "envelope.update_recipient"     => &envelope_update_recipient/1,
      "envelope.audit_events"         => &envelope_audit_events/1,
      "recipient.add"                 => &recipient_add/1,
      "template.find"                 => &template_find/1,
      "template.get"                  => &template_get/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      envelope_id:           "11111111-mock-envl-0000-000000000001",
      envelope_subject:      "Beispiel Mock-Vertrag zur Unterschrift",
      envelope_status:       "sent",
      recipient_id:          "MOCKRECIPIENT001",
      recipient_name:        "Alex Beispiel",
      recipient_email:       "alex.beispiel@beispiel-shop-demo.example",
      document_id:           "MOCKDOC001",
      document_name:         "Beispiel-Vertragsdokument.pdf",
      template_id:           "33333333-mock-tmpl-0000-000000000001",
      template_id_existing:  "MOCKTEMPLATE1",
      template_name:         "Beispiel Mock-Vorlage",
      audit_event_id:        "MOCKAUDIT001",
      audit_event_action:    "Sent",
      audit_event_timestamp: "2026-01-01T00:00:00.0000000Z",
      # base64 of "MOCK\n" — keeps the round-trip deterministic
      # without a real binary blob in the fixture.
      document_content_b64:  "TU9DSwo=",
      document_content_type: "application/pdf"
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

  defp envelope_list_recipients(_args) do
    %{recipient_id: id, recipient_name: name, recipient_email: email} = sentinels()

    %{
      "recipients" => [
        %{
          "recipient_id" => id,
          "name"         => name,
          "email"        => email,
          "status"       => "sent",
          "role_name"    => "Signer 1"
        }
      ]
    }
  end

  defp envelope_list_documents(_args) do
    %{document_id: id, document_name: name} = sentinels()

    %{
      "documents" => [
        %{
          "document_id" => id,
          "name"        => name,
          "type"        => "content"
        }
      ]
    }
  end

  defp envelope_download_document(_args) do
    %{
      document_content_b64:  b64,
      document_content_type: ctype
    } = sentinels()

    %{
      "content_b64"  => b64,
      "content_type" => ctype
    }
  end

  defp envelope_create_from_template(_args) do
    %{envelope_id: id} = sentinels()

    %{
      "envelope_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp envelope_resend(_args) do
    %{"ok" => true}
  end

  defp envelope_update_recipient(_args) do
    %{"recipient_id" => "updated"}
  end

  defp envelope_audit_events(_args) do
    %{
      audit_event_id:        ev_id,
      audit_event_action:    action,
      audit_event_timestamp: ts
    } = sentinels()

    %{
      "events" => [
        %{
          "event_id"  => ev_id,
          "Action"    => action,
          "LogTime"   => ts
        }
      ]
    }
  end

  defp template_get(_args) do
    %{template_id_existing: id, template_name: name} = sentinels()

    %{
      "template" => %{
        "templateId" => id,
        "name"       => name
      }
    }
  end
end
