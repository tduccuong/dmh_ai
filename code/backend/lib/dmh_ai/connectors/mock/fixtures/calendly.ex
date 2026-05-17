# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Calendly do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Calendly connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  Sentinel identifiers (German fake event-types + invitee names)
  let runbooks + tests assert mechanically that the chain's output
  came from the connector path rather than the model inventing
  similar-sounding strings.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "user.me"                    => &user_me/1,
      "event_type.list"            => &event_type_list/1,
      "event_type.available_slots" => &event_type_available_slots/1,
      "event.list"                 => &event_list/1,
      "event.invitees"             => &event_invitees/1,
      "single_use_link.create"     => &single_use_link_create/1,
      "event.cancel"               => &event_cancel/1,
      "event.mark_no_show"         => &event_mark_no_show/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      user_name:           "Karla Beraterin",
      user_email:          "karla.beraterin@dmh-calendly-demo.example",
      user_uri:            "https://api.calendly.com/users/MOCK_USER_AAAA",
      event_type_name:     "Discovery Call (30 min)",
      event_type_uri:      "https://api.calendly.com/event_types/MOCK_EVT_BBBB",
      event_type_slug:     "discovery-30",
      event_uri:           "https://api.calendly.com/scheduled_events/MOCK_EVENT_CCCC",
      event_name:          "Discovery Call (30 min)",
      invitee_uri:         "https://api.calendly.com/scheduled_events/MOCK_EVENT_CCCC/invitees/MOCK_INV_DDDD",
      invitee_email:       "brian.kunde@mustermann-gmbh.example",
      invitee_name:        "Brian Kunde",
      booking_url:         "https://calendly.com/d/mock-single-use-EEEE",
      no_show_uri:         "https://api.calendly.com/invitee_no_shows/MOCK_NS_FFFF"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp user_me(_args) do
    s = sentinels()

    %{
      "user" => %{
        "uri"            => s.user_uri,
        "name"           => s.user_name,
        "email"          => s.user_email,
        "timezone"       => "Europe/Berlin",
        "scheduling_url" => "https://calendly.com/karla-beraterin"
      }
    }
  end

  defp event_type_list(_args) do
    s = sentinels()

    %{
      "event_types" => [
        %{
          "uri"             => s.event_type_uri,
          "name"            => s.event_type_name,
          "slug"            => s.event_type_slug,
          "duration"        => 30,
          "active"          => true,
          "scheduling_url"  => "https://calendly.com/karla-beraterin/discovery-30"
        }
      ]
    }
  end

  defp event_type_available_slots(_args) do
    %{
      "slots" => [
        %{
          "start_time"     => "2026-05-20T09:00:00.000000Z",
          "status"         => "available",
          "scheduling_url" => "https://calendly.com/karla-beraterin/discovery-30/2026-05-20T09:00"
        },
        %{
          "start_time"     => "2026-05-20T10:00:00.000000Z",
          "status"         => "available",
          "scheduling_url" => "https://calendly.com/karla-beraterin/discovery-30/2026-05-20T10:00"
        },
        %{
          "start_time"     => "2026-05-20T14:30:00.000000Z",
          "status"         => "available",
          "scheduling_url" => "https://calendly.com/karla-beraterin/discovery-30/2026-05-20T14:30"
        }
      ]
    }
  end

  defp event_list(_args) do
    s = sentinels()

    %{
      "events" => [
        %{
          "uri"        => s.event_uri,
          "name"       => s.event_name,
          "status"     => "active",
          "start_time" => "2026-05-20T09:00:00.000000Z",
          "end_time"   => "2026-05-20T09:30:00.000000Z",
          "location"   => "https://meet.google.com/mock-meet-link"
        }
      ]
    }
  end

  defp event_invitees(_args) do
    s = sentinels()

    %{
      "invitees" => [
        %{
          "uri"       => s.invitee_uri,
          "name"      => s.invitee_name,
          "email"     => s.invitee_email,
          "status"    => "active",
          "responses" => []
        }
      ]
    }
  end

  defp single_use_link_create(args) do
    s = sentinels()

    %{
      "booking_url" => s.booking_url <> "-" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "owner"       => Map.get(args, "event_type_uri") || s.event_type_uri
    }
  end

  defp event_cancel(args) do
    %{
      "cancelled" => true,
      "event_uri" => Map.get(args, "event_uri")
    }
  end

  defp event_mark_no_show(args) do
    s = sentinels()

    %{
      "marked"      => true,
      "no_show_uri" => s.no_show_uri <> "-" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "invitee_uri" => Map.get(args, "invitee_uri")
    }
  end
end
