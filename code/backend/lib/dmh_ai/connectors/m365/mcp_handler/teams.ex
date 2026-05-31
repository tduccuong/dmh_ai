# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Teams do
  @moduledoc """
  Microsoft Teams surface — `teams.create_meeting`,
  `teams.list_channels`, `teams.post_channel_message`. Channel ids
  look like `19:<base64>@thread.tacv2`, hence the `:`/`@` in the
  shared `safe_path_id` whitelist; team ids are plain UUIDs.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers

  @graph_base Helpers.graph_base()
  @graph_root Helpers.graph_root()

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "teams.create_meeting" => %FunctionSpec{
        method:  :post,
        url:     "#{@graph_base}/onlineMeetings",
        request: &teams_create_meeting_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{
                      "join_url"   => body["joinWebUrl"],
                      "meeting_id" => body["id"],
                      "subject"    => body["subject"]
                    }}
                  end,
        doc: "Create a Teams online meeting and return the join URL."
      },
      "teams.list_channels" => %FunctionSpec{
        handler: &teams_list_channels/2,
        doc:     "List channels of a Microsoft Teams team."
      },
      "teams.post_channel_message" => %FunctionSpec{
        handler: &teams_post_channel_message/2,
        doc:     "Post a message into a Teams channel (HTML body)."
      }
    }
  end

  # ─── teams.create_meeting — POST /me/onlineMeetings ───────────────────

  defp teams_create_meeting_request(args, _ctx) do
    # Default to "ad-hoc meeting now → next hour" when args are
    # blank. Outlook's UI does the same — clicking "New Teams
    # meeting" with no times set creates an immediate room.
    now = DateTime.utc_now()
    start_iso = Map.get(args, "start") || DateTime.to_iso8601(now)
    end_iso   = Map.get(args, "end")   || DateTime.to_iso8601(DateTime.add(now, 3600, :second))
    subject   = Map.get(args, "subject", "Ad-hoc meeting")

    [
      json: %{
        "startDateTime" => start_iso,
        "endDateTime"   => end_iso,
        "subject"       => subject
      }
    ]
  end

  # ─── teams.list_channels — GET /teams/{id}/channels ───────────────────
  # vendor: GET /v1.0/teams/{team_id}/channels?$top=N
  # docs:   https://learn.microsoft.com/graph/api/channel-list

  defp teams_list_channels(args, ctx) do
    team_id = Helpers.safe_path_id(args["team_id"])
    limit   = Map.get(args, "limit", 25)

    opts = [
      url:    "#{@graph_root}/teams/#{team_id}/channels",
      params: [{"$top", limit}, {"$select", "id,displayName,description,membershipType"}]
    ]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => channels}} when is_list(channels) ->
        flat = Enum.map(channels, &normalise_channel/1)
        {:ok, %{"channels" => flat}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_channel(c) do
    %{
      "id"              => c["id"],
      "name"            => c["displayName"],
      "description"     => c["description"],
      "membership_type" => c["membershipType"]
    }
  end

  # ─── teams.post_channel_message — POST channel message ────────────────
  # vendor: POST /v1.0/teams/{team_id}/channels/{channel_id}/messages
  # docs:   https://learn.microsoft.com/graph/api/chatmessage-post

  defp teams_post_channel_message(args, ctx) do
    team_id    = Helpers.safe_path_id(args["team_id"])
    channel_id = Helpers.safe_path_id(args["channel_id"])
    body_text  = args["body"] || ""
    subject    = Map.get(args, "subject")

    url = "#{@graph_root}/teams/#{team_id}/channels/#{channel_id}/messages"

    body =
      %{
        "body" => %{"contentType" => "html", "content" => body_text}
      }
      |> Helpers.maybe_put_kv("subject", subject)

    case RestBridge.raw_request(:post, Helpers.with_bearer([url: url, json: body], ctx)) do
      {:ok, status, resp} when status in 200..299 and is_map(resp) ->
        {:ok, %{"message_id" => to_string(resp["id"] || "")}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end
end
