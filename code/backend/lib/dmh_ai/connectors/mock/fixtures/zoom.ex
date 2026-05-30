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
      "meeting.create"            => &meeting_create/1,
      "meeting.find"              => &meeting_find/1,
      "meeting.get"               => &meeting_get/1,
      "meeting.update"            => &meeting_update/1,
      "meeting.delete"            => &meeting_delete/1,
      "meeting.list_registrants"  => &meeting_list_registrants/1,
      "meeting.add_registrant"    => &meeting_add_registrant/1,
      "meeting.list_participants" => &meeting_list_participants/1,
      "recording.find"            => &recording_find/1,
      "recording.get"             => &recording_get/1,
      "recording.delete"          => &recording_delete/1,
      "user.find"                 => &user_find/1,
      "webinar.create"            => &webinar_create/1,
      "webinar.find"              => &webinar_find/1,
      "webinar.add_registrant"    => &webinar_add_registrant/1,
      "webinar.update"            => &webinar_update/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      meeting_id:     "99MOCKMTG0001",
      meeting_uuid:   "/UMOCKABCD0001==",
      meeting_topic:  "Beispiel-Besprechung Demo",
      join_url:       "https://zoom.us/j/99MOCKMTG0001",
      user_id:        "uMOCKUSER0001",
      user_email:     "klara.beispiel@beispiel-team-demo.example",
      webinar_id:     "88MOCKWEB0001",
      webinar_topic:  "Beispiel-Webinar Demo",
      recording_id:   "MOCKREC0001",
      registrant_id:  "MOCKREG0001"
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

  defp meeting_list_registrants(_args) do
    %{user_email: email, registrant_id: rid} = sentinels()

    %{
      "registrants" => [
        %{
          "id"         => rid,
          "email"      => email,
          "first_name" => "Klara",
          "last_name"  => "Beispiel",
          "status"     => "approved"
        }
      ]
    }
  end

  defp meeting_add_registrant(_args) do
    %{registrant_id: rid, meeting_id: mid} = sentinels()

    %{
      "registrant_id" => rid,
      "join_url"      => "https://zoom.us/w/" <> mid
    }
  end

  defp meeting_list_participants(_args) do
    %{user_email: email} = sentinels()

    %{
      "participants" => [
        %{
          "id"            => "pMOCKPART0001",
          "user_email"    => email,
          "name"          => "Klara Beispiel",
          "duration"      => 1800,
          "join_time"     => "2026-05-29T10:00:00Z",
          "leave_time"    => "2026-05-29T10:30:00Z"
        }
      ]
    }
  end

  defp recording_get(_args) do
    %{meeting_id: mid, meeting_topic: topic, recording_id: rid} = sentinels()

    %{
      "recording" => %{
        "id"              => mid,
        "topic"           => topic,
        "recording_count" => 1,
        "recording_files" => [
          %{
            "id"            => rid,
            "file_type"     => "MP4",
            "download_url"  => "https://zoom.us/rec/download/" <> rid,
            "play_url"      => "https://zoom.us/rec/play/" <> rid,
            "recording_type" => "shared_screen_with_speaker_view"
          }
        ]
      }
    }
  end

  defp recording_delete(_args) do
    %{"ok" => true}
  end

  defp webinar_find(_args) do
    %{webinar_id: id, webinar_topic: topic} = sentinels()

    %{
      "webinars" => [
        %{
          "id"        => id,
          "topic"     => topic,
          "start_url" => "https://zoom.us/s/" <> id
        }
      ]
    }
  end

  defp webinar_add_registrant(_args) do
    %{registrant_id: rid, webinar_id: wid} = sentinels()

    %{
      "registrant_id" => rid,
      "join_url"      => "https://zoom.us/webinar/register/confirm/" <> wid
    }
  end

  defp webinar_update(_args) do
    %{"webinar_id" => "updated"}
  end
end
