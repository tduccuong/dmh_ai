# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Slack do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Slack connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  The values returned here are the connector's *mapped* shapes (post
  `MCPHandler` translation), so a runbook / test asserts on the
  canonical keys (`ts`, `channels`, `messages`, `users`, …), not
  Slack's raw envelope.

  Sentinel identifiers (Slack-style channel / message / user IDs +
  a fake channel name) let runbooks + tests assert mechanically that
  the chain's output came from the connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "message.send"       => &message_send/1,
      "message.update"     => &message_update/1,
      "channel.find"       => &channel_find/1,
      "channel.history"    => &channel_history/1,
      "message.find"       => &message_find/1,
      "user.find_by_email" => &user_find_by_email/1,
      "user.list"          => &user_list/1,
      "reaction.add"       => &reaction_add/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      channel_id:   "C0MOCKCHAN001",
      channel_name: "beispiel-team-demo",
      message_ts:   "1700000000.000100",
      user_id:      "U0MOCKUSER001",
      user_name:    "klara.beispiel",
      user_email:   "klara.beispiel@beispiel-team-demo.example"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp message_send(_args) do
    %{channel_id: chan, message_ts: ts} = sentinels()

    %{
      "ts"      => ts <> Integer.to_string(:erlang.unique_integer([:positive])),
      "channel" => chan
    }
  end

  defp message_update(_args) do
    %{message_ts: ts} = sentinels()

    %{"ts" => ts}
  end

  defp channel_find(_args) do
    %{channel_id: id, channel_name: name} = sentinels()

    %{
      "channels" => [
        %{
          "id"   => id,
          "name" => name
        }
      ]
    }
  end

  defp channel_history(_args) do
    %{message_ts: ts, user_id: user} = sentinels()

    %{
      "messages" => [
        %{
          "ts"   => ts,
          "user" => user,
          "text" => "Beispiel-Nachricht im Demokanal."
        }
      ]
    }
  end

  defp message_find(_args) do
    %{channel_id: chan, message_ts: ts, user_id: user} = sentinels()

    %{
      "messages" => [
        %{
          "ts"      => ts,
          "user"    => user,
          "channel" => %{"id" => chan},
          "text"    => "Beispiel-Treffer aus der Suche."
        }
      ]
    }
  end

  defp user_find_by_email(_args) do
    %{user_id: id, user_name: name, user_email: email} = sentinels()

    %{
      "user" => %{
        "id"    => id,
        "name"  => name,
        "email" => email
      }
    }
  end

  defp user_list(_args) do
    %{user_id: id, user_name: name, user_email: email} = sentinels()

    %{
      "users" => [
        %{
          "id"    => id,
          "name"  => name,
          "email" => email
        }
      ]
    }
  end

  defp reaction_add(_args) do
    %{"ok" => true}
  end
end
