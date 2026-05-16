# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler do
  @moduledoc """
  Function-spec map for the Google Workspace connector consumed by the
  generic `Connectors.MCPServer`. Each function declares a
  `FunctionSpec` — most are 1:1 mappings to a Gmail v1 / Calendar v3 /
  Drive v3 endpoint; three need custom orchestration (fan-out
  gmail.search, slot computation on freebusy, multipart drive
  upload). The custom logic lives here, not in the bridge.

  Vendor anchors per function match `Connectors.GoogleWorkspace`'s
  manifest comments — same `# vendor: …` URL grounding.
  """

  alias DmhAi.Connectors.MCPServer.{ErrorMap, RestBridge, FunctionSpec}
  require Logger

  @gmail_base    "https://gmail.googleapis.com/gmail/v1/users/me"
  @calendar_base "https://www.googleapis.com/calendar/v3"
  @drive_base    "https://www.googleapis.com/drive/v3"
  @drive_upload  "https://www.googleapis.com/upload/drive/v3"

  @doc """
  Connector handler entry consumed by
  `Connectors.MCPServer.Registry.put/1` at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "google_workspace", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "gmail.search" => %FunctionSpec{
        handler: &gmail_search/2,
        doc:     "List Gmail messages matching the query, with sender + subject headers."
      },
      "gmail.send" => %FunctionSpec{
        method:  :post,
        url:     "#{@gmail_base}/messages/send",
        request: &gmail_send_request/2,
        doc:     "Send a plain-text Gmail message."
      },
      "gcal.find_free_slots" => %FunctionSpec{
        handler: &gcal_find_free_slots/2,
        doc:     "List free slots of `duration_min` length within a window."
      },
      "gcal.create_event" => %FunctionSpec{
        method:  :post,
        url:     "#{@calendar_base}/calendars/primary/events",
        request: &gcal_create_event_request/2,
        response: fn 200, body -> {:ok, %{"event_id" => body["id"], "html_link" => body["htmlLink"]}}
                    s, _b when s in 200..299 -> {:ok, %{}} end,
        doc:     "Create a Calendar event on the primary calendar."
      },
      "drive.list" => %FunctionSpec{
        method:  :get,
        url:     "#{@drive_base}/files",
        request: &drive_list_request/2,
        response: fn 200, body -> {:ok, %{"items" => Map.get(body, "files", [])}}
                    s, _b when s in 200..299 -> {:ok, %{}} end,
        doc:     "List Drive files matching a folder or query."
      },
      "drive.upload" => %FunctionSpec{
        handler: &drive_upload/2,
        doc:     "Upload a file to Drive (multipart)."
      }
    }
  end

  # ─── gmail.search — list then fan-out for headers ─────────────────────

  # vendor: GET /gmail/v1/users/me/messages           (list ids)
  # vendor: GET /gmail/v1/users/me/messages/{id}      (per-message metadata)
  defp gmail_search(args, ctx) do
    list_query = [
      {"q",          Map.get(args, "query", "")},
      {"maxResults", Map.get(args, "limit", 10)}
    ]

    with {:ok, %{"messages" => msgs}} <-
           bare_get("#{@gmail_base}/messages", list_query, ctx),
         hydrated <- Enum.map(msgs, fn %{"id" => id} -> fetch_metadata(id, ctx) end) do
      messages =
        hydrated
        |> Enum.flat_map(fn
          {:ok, m} -> [m]
          _        -> []
        end)

      {:ok, %{"messages" => messages, "queried" => Map.get(args, "query", "")}}
    else
      {:ok, %{}} ->
        # Empty inbox / no matches — Google omits `messages` key.
        {:ok, %{"messages" => [], "queried" => Map.get(args, "query", "")}}

      {:error, _} = err ->
        err
    end
  end

  defp fetch_metadata(id, ctx) do
    url = "#{@gmail_base}/messages/#{id}"
    query = [
      {"format",          "metadata"},
      {"metadataHeaders", "From"},
      {"metadataHeaders", "Subject"},
      {"metadataHeaders", "Date"}
    ]

    case bare_get(url, query, ctx) do
      {:ok, %{"id" => mid, "payload" => %{"headers" => headers}} = msg} ->
        {:ok,
         %{
           "id"          => mid,
           "from"        => header(headers, "From"),
           "subject"     => header(headers, "Subject"),
           "received_at" => header(headers, "Date"),
           "snippet"     => Map.get(msg, "snippet", "")
         }}

      other ->
        other
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, "", fn
      %{"name" => ^name, "value" => v} -> v
      _ -> nil
    end)
  end

  # ─── gmail.send — RFC-2822 MIME compose, base64url-encoded `raw` ──────

  defp gmail_send_request(args, _ctx) do
    mime = compose_mime(args["to"], args["subject"], args["body"])
    encoded = mime |> Base.url_encode64(padding: false)
    [json: %{"raw" => encoded}, headers: [{"content-type", "application/json"}]]
  end

  defp compose_mime(to, subject, body) do
    [
      "To: ", to, "\r\n",
      "Subject: ", subject, "\r\n",
      "MIME-Version: 1.0\r\n",
      "Content-Type: text/plain; charset=UTF-8\r\n",
      "\r\n",
      body || ""
    ]
    |> IO.iodata_to_binary()
  end

  # ─── gcal.find_free_slots — freebusy.query + slot computation ─────────

  # vendor: POST /calendar/v3/freeBusy
  # Returns busy intervals; the shim computes free slots of
  # `duration_min` length within `[between_from, between_to]`.
  defp gcal_find_free_slots(args, ctx) do
    body = %{
      "timeMin" => args["between_from"],
      "timeMax" => args["between_to"],
      "items"   => [%{"id" => "primary"}]
    }

    case bare_post("#{@calendar_base}/freeBusy", body, ctx) do
      {:ok, %{"calendars" => %{"primary" => %{"busy" => busy}}}} ->
        slots =
          compute_free_slots(
            args["between_from"],
            args["between_to"],
            Map.get(args, "duration_min", 30),
            busy
          )

        {:ok, %{"slots" => slots}}

      {:ok, _} ->
        {:ok, %{"slots" => []}}

      err ->
        err
    end
  end

  # Walk the [from, to] window, skipping over busy intervals; emit
  # every (start, start+duration) pair where start+duration ≤ next
  # busy boundary. Naive but adequate for the function's contract; if
  # SMEs need ranked slots / preferences, that's a separate function.
  defp compute_free_slots(from_iso, to_iso, duration_min, busy_intervals) do
    with {:ok, from_dt, _} <- DateTime.from_iso8601(from_iso),
         {:ok, to_dt, _}   <- DateTime.from_iso8601(to_iso) do
      busy =
        busy_intervals
        |> Enum.map(fn %{"start" => bs, "end" => be} ->
          {:ok, bs_dt, _} = DateTime.from_iso8601(bs)
          {:ok, be_dt, _} = DateTime.from_iso8601(be)
          {bs_dt, be_dt}
        end)
        |> Enum.sort_by(&elem(&1, 0), DateTime)

      duration_s = duration_min * 60

      walk_slots(from_dt, to_dt, duration_s, busy, [])
      |> Enum.reverse()
    else
      _ -> []
    end
  end

  defp walk_slots(cursor, to_dt, dur_s, busy, acc) do
    cond do
      DateTime.compare(DateTime.add(cursor, dur_s, :second), to_dt) == :gt ->
        acc

      true ->
        slot_end = DateTime.add(cursor, dur_s, :second)
        next_busy_start = next_busy_start(busy, cursor)

        cond do
          # Cursor falls inside a busy interval → jump to its end.
          inside_busy?(cursor, busy) ->
            new_cursor = first_busy_containing(busy, cursor) |> elem(1)
            walk_slots(new_cursor, to_dt, dur_s, busy, acc)

          # Slot end would overlap the next busy → jump cursor past it.
          next_busy_start != nil and
              DateTime.compare(slot_end, next_busy_start) == :gt ->
            walk_slots(next_busy_start, to_dt, dur_s, busy, acc)

          true ->
            slot = %{
              "start"        => DateTime.to_iso8601(cursor),
              "end"          => DateTime.to_iso8601(slot_end),
              "duration_min" => div(dur_s, 60)
            }

            # Advance by full duration to next candidate slot.
            walk_slots(slot_end, to_dt, dur_s, busy, [slot | acc])
        end
    end
  end

  defp inside_busy?(dt, busy) do
    Enum.any?(busy, fn {bs, be} ->
      DateTime.compare(dt, bs) != :lt and DateTime.compare(dt, be) == :lt
    end)
  end

  defp first_busy_containing(busy, dt) do
    Enum.find(busy, fn {bs, be} ->
      DateTime.compare(dt, bs) != :lt and DateTime.compare(dt, be) == :lt
    end)
  end

  defp next_busy_start(busy, after_dt) do
    busy
    |> Enum.find(fn {bs, _be} -> DateTime.compare(bs, after_dt) != :lt end)
    |> case do
      nil      -> nil
      {bs, _}  -> bs
    end
  end

  # ─── gcal.create_event — events.insert ────────────────────────────────

  defp gcal_create_event_request(args, _ctx) do
    body = %{
      "summary" => args["title"],
      "start"   => %{"dateTime" => args["start"]},
      "end"     => %{"dateTime" => args["end"]},
      "attendees" => (args["attendees"] || []) |> Enum.map(fn email -> %{"email" => email} end)
    }

    [json: body]
  end

  # ─── drive.list — files.list with folder_id → `q` clause ──────────────

  defp drive_list_request(args, _ctx) do
    folder_clause =
      case Map.get(args, "folder_id") do
        nil -> nil
        ""  -> nil
        id  -> "'#{id}' in parents"
      end

    user_q = Map.get(args, "query")

    q =
      [folder_clause, user_q]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(" and ")

    query = if q == "", do: [], else: [{"q", q}]
    [params: query ++ [{"pageSize", Map.get(args, "limit", 25)}]]
  end

  # ─── drive.upload — multipart upload (metadata + content parts) ───────

  defp drive_upload(args, ctx) do
    name = args["name"]
    content = args["content"] || ""
    mime_type = Map.get(args, "mime_type", "application/octet-stream")

    boundary = "----dmh-ai-boundary-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    metadata = Jason.encode!(%{"name" => name})

    body = [
      "--", boundary, "\r\n",
      "Content-Type: application/json; charset=UTF-8\r\n\r\n",
      metadata, "\r\n",
      "--", boundary, "\r\n",
      "Content-Type: ", mime_type, "\r\n\r\n",
      content, "\r\n",
      "--", boundary, "--"
    ]
    |> IO.iodata_to_binary()

    url = "#{@drive_upload}/files?uploadType=multipart"
    headers = [
      {"content-type", "multipart/related; boundary=#{boundary}"},
      {"authorization", "Bearer #{ctx[:bearer_token] || ""}"}
    ]

    case RestBridge.raw_request(:post, url: url, headers: headers, body: body) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, %{"file_id" => body["id"], "name" => body["name"], "mime_type" => body["mimeType"]}}

      {:ok, status, body} ->
        {:error, ErrorMap.classify(status, body)}

      {:error, _} ->
        {:error, :transport_error}
    end
  end

  # HTTP sub-calls go through RestBridge helpers so the test stub
  # (`:__rest_bridge_http_stub__`) intercepts every outbound
  # request from this handler — both FunctionSpec-driven functions AND
  # the custom-handler fan-outs / multipart uploads.

  defp bare_get(url, query, ctx),     do: RestBridge.simple_get(url, query, ctx)
  defp bare_post(url, json_body, ctx), do: RestBridge.simple_post(url, json_body, ctx)
end
