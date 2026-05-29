# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Zoom do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Zoom connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  The values returned here are the connector's *mapped* shapes (post
  `MCPHandler` translation), so a runbook / test asserts on the
  canonical keys (`meeting_id`, `meetings`, `recordings`, `user`, …),
  not Zoom's raw envelope.

  Sentinel identifiers (obviously-fake Zoom meeting / user / webinar
  IDs + a fake meeting topic) let runbooks + tests assert
  mechanically that the chain's output came from the connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "meeting.create" => &meeting_create/1,
      "meeting.find"   => &meeting_find/1,
      "meeting.get"    => &meeting_get/1,
      "meeting.update" => &meeting_update/1,
      "meeting.delete" => &meeting_delete/1,
      "recording.find" => &recording_find/1,
      "user.find"      => &user_find/1,
      "webinar.create" => &webinar_create/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      meeting_id:    "99MOCKMTG0001",
      meeting_topic: "Beispiel-Besprechung Demo",
      join_url:      "https://zoom.us/j/99MOCKMTG0001",
      user_id:       "uMOCKUSER0001",
      user_email:    "klara.beispiel@beispiel-team-demo.example",
      webinar_id:    "88MOCKWEB0001",
      recording_id:  "77MOCKREC0001"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp meeting_create(_args) do
    %{meeting_id: id, join_url: url} = sentinels()

    %{
      "meeting_id" => id <> Integer.to_string(:erlang.unique_integer([:positive])),
      "join_url"   => url
    }
  end

  defp meeting_find(_args) do
    %{meeting_id: id, meeting_topic: topic, join_url: url} = sentinels()

    %{
      "meetings" => [
        %{
          "id"       => id,
          "topic"    => topic,
          "join_url" => url
        }
      ]
    }
  end

  defp meeting_get(_args) do
    %{meeting_id: id, meeting_topic: topic, join_url: url} = sentinels()

    %{
      "meeting" => %{
        "id"       => id,
        "topic"    => topic,
        "join_url" => url,
        "duration" => 30
      }
    }
  end

  defp meeting_update(_args) do
    %{"meeting_id" => "updated"}
  end

  defp meeting_delete(_args) do
    %{"ok" => true}
  end

  defp recording_find(_args) do
    %{meeting_id: id, meeting_topic: topic, recording_id: rec} = sentinels()

    %{
      "recordings" => [
        %{
          "id"            => id,
          "topic"         => topic,
          "recording_id"  => rec,
          "recording_count" => 1
        }
      ]
    }
  end

  defp user_find(_args) do
    %{user_id: id, user_email: email} = sentinels()

    %{
      "user" => %{
        "id"    => id,
        "email" => email
      }
    }
  end

  defp webinar_create(_args) do
    %{webinar_id: id} = sentinels()

    %{
      "webinar_id"       => id <> Integer.to_string(:erlang.unique_integer([:positive])),
      "registration_url" => "https://zoom.us/webinar/register/" <> id
    }
  end
end
