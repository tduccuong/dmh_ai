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
  identifies lists by integer id too — sentinels here preserve those
  shapes. The fixture returns already-mapped responses
  (`{contacts: [...]}`, `{contact_id: 1900001}`, …) matching what the
  vendor MCP exposes to callers downstream of the REST translation.

  Sentinel identifiers (obviously-fake Brevo contact / list / message
  ids + a fake contact email) let runbooks + tests assert mechanically
  that the chain's output came from the connector path.
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
      "email.send"     => &email_send/1,
      "list.find"      => &list_find/1,
      "list.create"    => &list_create/1
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
      list_id:       90_001
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

  defp email_send(_args) do
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
end
