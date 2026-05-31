# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Gmail do
  @moduledoc """
  Gmail surface of the Google Workspace MCPHandler — `gmail.search`,
  `gmail.send`, `gmail.reply`, `gmail.read`, `gmail.label`,
  `gmail.create_draft`. MIME compose / parse / header helpers live
  in `__MODULE__.Mime`.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.GoogleWorkspace.MCPHandler.Helpers
  alias __MODULE__.Mime

  @gmail_base "https://gmail.googleapis.com/gmail/v1/users/me"

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "gmail.search" => %FunctionSpec{
        handler: &gmail_search/2,
        doc:     "List Gmail messages matching the query, with sender + subject headers."
      },
      "gmail.send" => %FunctionSpec{
        method:  :post,
        url:     "#{@gmail_base}/messages/send",
        request: &gmail_send_request/2,
        response: fn 200, body  -> {:ok, %{"message_id" => body["id"], "thread_id" => body["threadId"]}}
                    s,   _body when s in 200..299 -> {:ok, %{}} end,
        doc:     "Send a plain-text Gmail message."
      },
      "gmail.reply" => %FunctionSpec{
        method:  :post,
        url:     "#{@gmail_base}/messages/send",
        request: &gmail_reply_request/2,
        response: fn 200, body  -> {:ok, %{"message_id" => body["id"], "thread_id" => body["threadId"]}}
                    s,   _body when s in 200..299 -> {:ok, %{}} end,
        doc:     "Reply to a Gmail thread (attaches threadId + In-Reply-To header)."
      },
      "gmail.read" => %FunctionSpec{
        handler: &gmail_read/2,
        doc:     "Read a Gmail message in full (headers, body, snippet, attachments)."
      },
      "gmail.label" => %FunctionSpec{
        handler: &gmail_label/2,
        doc:     "Add and / or remove labels on a Gmail message."
      },
      "gmail.create_draft" => %FunctionSpec{
        method:  :post,
        url:     "#{@gmail_base}/drafts",
        request: &gmail_create_draft_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"draft_id" => body["id"], "message_id" => get_in(body, ["message", "id"])}}
                  end,
        doc:     "Create a Gmail draft (plain-text MIME)."
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
           Helpers.bare_get("#{@gmail_base}/messages", list_query, ctx),
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

    case Helpers.bare_get(url, query, ctx) do
      {:ok, %{"id" => mid, "payload" => %{"headers" => headers}} = msg} ->
        {:ok,
         %{
           "id"          => mid,
           "from"        => Mime.header(headers, "From"),
           "subject"     => Mime.header(headers, "Subject"),
           "received_at" => Mime.header(headers, "Date"),
           "snippet"     => Map.get(msg, "snippet", "")
         }}

      other ->
        other
    end
  end

  # ─── gmail.send — RFC-2822 MIME compose, base64url-encoded `raw` ──────

  defp gmail_send_request(args, _ctx) do
    mime    = Mime.compose_text(args["to"], args["subject"], args["body"])
    encoded = Base.url_encode64(mime, padding: false)
    [json: %{"raw" => encoded}, headers: [{"content-type", "application/json"}]]
  end

  # ─── gmail.reply — RFC-2822 with In-Reply-To header + threadId ────────

  defp gmail_reply_request(args, _ctx) do
    mime =
      Mime.compose_reply(
        args["to"],
        args["subject"],
        Map.get(args, "in_reply_to_message_id"),
        args["body"]
      )

    encoded = Base.url_encode64(mime, padding: false)

    [
      json: %{
        "raw"      => encoded,
        "threadId" => args["thread_id"]
      },
      headers: [{"content-type", "application/json"}]
    ]
  end

  # ─── gmail.read — full message envelope + flattened headers ───────────

  # vendor: GET /gmail/v1/users/me/messages/{id}?format=full
  # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/get
  defp gmail_read(args, ctx) do
    message_id = Helpers.safe_path_id(args["message_id"])
    url        = "#{@gmail_base}/messages/#{message_id}"

    opts = [url: url, params: [{"format", "full"}]]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        {:ok, %{"message" => normalise_full_message(body)}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_full_message(m) do
    headers = get_in(m, ["payload", "headers"]) || []

    %{
      "id"            => m["id"],
      "thread_id"     => m["threadId"],
      "subject"       => Mime.header(headers, "Subject"),
      "from"          => Mime.header(headers, "From"),
      "to"            => Mime.header(headers, "To"),
      "received_at"   => Mime.header(headers, "Date"),
      "snippet"       => m["snippet"],
      "body"          => Mime.extract_body(m["payload"]),
      "label_ids"     => m["labelIds"] || [],
      "attachments"   => Mime.extract_attachments(m["payload"])
    }
  end

  # ─── gmail.label — modify label ids on a message ──────────────────────

  # vendor: POST /gmail/v1/users/me/messages/{id}/modify
  # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.messages/modify
  defp gmail_label(args, ctx) do
    message_id = Helpers.safe_path_id(args["message_id"])
    add_ids    = args["add_label_ids"] || []
    rem_ids    = args["remove_label_ids"] || []

    cond do
      not is_list(add_ids) or not is_list(rem_ids) ->
        {:error, :invalid_argument}

      add_ids == [] and rem_ids == [] ->
        {:error, :invalid_argument}

      true ->
        url  = "#{@gmail_base}/messages/#{message_id}/modify"
        body = %{"addLabelIds" => add_ids, "removeLabelIds" => rem_ids}

        case RestBridge.raw_request(:post, Helpers.with_bearer([url: url, json: body], ctx)) do
          {:ok, status, resp} when status in 200..299 and is_map(resp) ->
            {:ok, %{"message_id" => resp["id"] || message_id}}

          {:ok, status, body} ->
            {:error, {:http, status, body}}

          {:error, _} = err ->
            err
        end
    end
  end

  # ─── gmail.create_draft — RFC-2822 MIME wrapped in a draft envelope ───

  # vendor: POST /gmail/v1/users/me/drafts
  # docs:   https://developers.google.com/gmail/api/reference/rest/v1/users.drafts/create
  defp gmail_create_draft_request(args, _ctx) do
    mime    = Mime.compose_text(args["to"], args["subject"], args["body"])
    encoded = Base.url_encode64(mime, padding: false)

    [
      json:    %{"message" => %{"raw" => encoded}},
      headers: [{"content-type", "application/json"}]
    ]
  end
end
