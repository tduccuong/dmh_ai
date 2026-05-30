# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Brevo do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Brevo connector functions.

  Brevo's MCP server is vendor-hosted (Brevo runs it themselves),
  so there is no in-process REST translator and no `mcp_handler_module`
  on the connector. This fixture exists so test suites that want to
  assert against a stable Brevo-shaped response (sentinel ids
  unlikely to collide with real Brevo records) have something to
  point at.

  Brevo identifies contacts by integer id (not opaque string) and
  identifies lists / templates / campaigns by integer id too —
  sentinels here preserve those shapes. The fixture returns
  already-mapped responses (`{contacts: [...]}`, `{contact_id: 1900001}`,
  ...) matching what the vendor MCP exposes to callers downstream of
  the REST translation.

  Sentinel identifiers (obviously-fake Brevo contact / list / template /
  campaign / message ids + a fake contact email + a tracked-events
  email) let runbooks + tests assert mechanically that the chain's
  output came from the connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: ...)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "contact.find"             => &contact_find/1,
      "contact.create"           => &contact_create/1,
      "contact.update"           => &contact_update/1,
      "contact.delete"           => &contact_delete/1,
      "contact.add_to_list"      => &contact_add_to_list/1,
      "contact.remove_from_list" => &contact_remove_from_list/1,
      "email.send"               => &email_send/1,
      "email.send_template"      => &email_send_template/1,
      "list.find"                => &list_find/1,
      "list.create"              => &list_create/1,
      "template.find"            => &template_find/1,
      "campaign.find"            => &campaign_find/1,
      "campaign.create"          => &campaign_create/1,
      "transactional.event.find" => &transactional_event_find/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      contact_id:    1_900_001,
      contact_email: "klara.beispiel@beispiel-shop-demo.example",
      message_id:    "<mock-message-id@brevo.test>",
      list_id:       90_001,
      template_id:   200_001,
      campaign_id:   300_001,
      event_email:   "tracked@beispiel.de"
    }
  end

  # ── Per-function fixtures (already-mapped shapes; no envelope) ──────

  defp contact_find(_args) do
    %{contact_id: id, contact_email: email} = sentinels()

    %{
      "contacts" => [
        %{
          "id"    => id,
          "email" => email
        }
      ]
    }
  end

  defp contact_create(_args) do
    %{contact_id: id} = sentinels()

    # Brevo returns an integer id; emit it as a string for the
    # manifest's `contact_id: :string` shape (the vendor MCP performs
    # the conversion in the real path).
    %{
      "contact_id" =>
        Integer.to_string(id + :erlang.unique_integer([:positive, :monotonic]))
    }
  end

  defp contact_update(_args) do
    %{"ok" => true}
  end

  defp contact_delete(_args) do
    %{"ok" => true}
  end

  defp contact_add_to_list(args) do
    # Echo the inbound emails-list length as the count, so test
    # assertions can match against the request shape without depending
    # on a hard-coded number.
    count =
      case Map.get(args, "emails") do
        list when is_list(list) -> length(list)
        _ -> 1
      end

    %{"contacts_added" => count}
  end

  defp contact_remove_from_list(args) do
    count =
      case Map.get(args, "emails") do
        list when is_list(list) -> length(list)
        _ -> 1
      end

    %{"contacts_removed" => count}
  end

  defp email_send(_args) do
    %{message_id: id} = sentinels()

    %{"message_id" => id}
  end

  defp email_send_template(_args) do
    %{message_id: id} = sentinels()

    %{"message_id" => id}
  end

  defp list_find(_args) do
    %{list_id: id} = sentinels()

    %{
      "lists" => [
        %{
          "id"   => id,
          "name" => "Beispiel-Liste Demo"
        }
      ]
    }
  end

  defp list_create(_args) do
    %{list_id: id} = sentinels()

    %{"list_id" => id}
  end

  defp template_find(_args) do
    %{template_id: id} = sentinels()

    %{
      "templates" => [
        %{
          "id"   => id,
          "name" => "Beispiel-Template Demo"
        }
      ]
    }
  end

  defp campaign_find(_args) do
    %{campaign_id: id} = sentinels()

    %{
      "campaigns" => [
        %{
          "id"     => id,
          "name"   => "Beispiel-Kampagne Demo",
          "status" => "draft"
        }
      ]
    }
  end

  defp campaign_create(_args) do
    %{campaign_id: id} = sentinels()

    %{"campaign_id" => id}
  end

  defp transactional_event_find(_args) do
    %{event_email: email} = sentinels()

    %{
      "events" => [
        %{
          "email" => email,
          "event" => "delivered"
        },
        %{
          "email" => email,
          "event" => "opened"
        }
      ]
    }
  end
end
