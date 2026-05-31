# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Mail do
  @moduledoc """
  Outlook Mail surface of the Microsoft 365 MCPHandler —
  `mail.search`, `mail.send`, `mail.reply`, `mail.read`,
  `mail.move_to_folder`. Outlook well-known mail folder ids accepted
  by `mail.move_to_folder` (in addition to mailbox folder ids):
  `inbox · archive · deleteditems · drafts · sentitems · junkemail`.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers
  require Logger

  @graph_base Helpers.graph_base()

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "mail.search" => %FunctionSpec{
        handler: &mail_search/2,
        doc:     "Search Outlook messages by KQL query, return id + from + subject + receivedDateTime."
      },
      "mail.send" => %FunctionSpec{
        method:  :post,
        url:     "#{@graph_base}/sendMail",
        request: &mail_send_request/2,
        # Graph's /sendMail returns 202 with no body. Surface a
        # plain "accepted: true" so the model can confirm send.
        response: fn 202, _ -> {:ok, %{"accepted" => true}}
                    s,   _ when s in 200..299 -> {:ok, %{"accepted" => true}} end,
        doc:     "Send a plain-text Outlook message."
      },
      "mail.reply" => %FunctionSpec{
        handler: &mail_reply/2,
        doc:     "Reply to an Outlook message (Graph preserves the conversation/thread)."
      },
      "mail.read" => %FunctionSpec{
        handler: &mail_read/2,
        doc:     "Fetch a single Outlook message with full body + attachments metadata."
      },
      "mail.move_to_folder" => %FunctionSpec{
        handler: &mail_move_to_folder/2,
        doc:     "Move an Outlook message to a destination folder (well-known id or mailbox folder id)."
      }
    }
  end

  # ─── mail.search — KQL $search with ConsistencyLevel header ───────────

  # vendor: GET /v1.0/me/messages?$search="..."&$top=N&$select=...
  defp mail_search(args, ctx) do
    q     = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 10)

    # Graph requires this header for $search on messages.
    extra_headers = [{"consistencylevel", "eventual"}]

    opts = [
      url:     "#{@graph_base}/messages",
      params: [
        {"$search", "\"#{q}\""},
        {"$top",    limit},
        {"$select", "id,subject,from,receivedDateTime,bodyPreview"}
      ],
      headers: extra_headers
    ]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => raw}} when is_list(raw) ->
        msgs =
          Enum.map(raw, fn m ->
            %{
              "id"          => m["id"],
              "from"        => get_in(m, ["from", "emailAddress", "address"]),
              "subject"     => m["subject"],
              "received_at" => m["receivedDateTime"],
              "snippet"     => m["bodyPreview"] || ""
            }
          end)

        {:ok, %{"messages" => msgs, "queried" => q}}

      {:ok, _status, body} ->
        {:error, :upstream_other}
        |> tap(fn _ -> Logger.warning("[M365] mail.search non-2xx: #{inspect(body)}") end)

      {:error, _} = err ->
        err
    end
  end

  # ─── mail.send — POST /me/sendMail ────────────────────────────────────

  defp mail_send_request(args, _ctx) do
    [
      json: %{
        "message" => %{
          "subject" => args["subject"],
          "body" => %{
            "contentType" => "Text",
            "content"     => args["body"]
          },
          "toRecipients" => [
            %{"emailAddress" => %{"address" => args["to"]}}
          ]
        },
        "saveToSentItems" => "true"
      }
    ]
  end

  # ─── mail.reply — POST /me/messages/{id}/reply ────────────────────────

  defp mail_reply(args, ctx) do
    message_id = args["message_id"]
    body_text  = args["body"] || ""

    url = "#{@graph_base}/messages/#{URI.encode(message_id)}/reply"

    body = %{
      "comment" => body_text
    }

    case RestBridge.raw_request(:post, Helpers.with_bearer([url: url, json: body], ctx)) do
      {:ok, status, _body} when status in 200..299 ->
        {:ok, %{"ok" => true, "message_id" => message_id}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── mail.read — GET /me/messages/{id} ────────────────────────────────
  # vendor: GET /v1.0/me/messages/{id}?$expand=attachments($select=…)
  # docs:   https://learn.microsoft.com/graph/api/message-get
  # Returns the message body + attachments metadata so the model can
  # reference attachment names + sizes without downloading them.

  defp mail_read(args, ctx) do
    message_id = Helpers.safe_path_id(args["message_id"])
    url        = "#{@graph_base}/messages/#{message_id}"

    opts = [
      url:    url,
      params: [
        {"$expand", "attachments($select=id,name,contentType,size)"},
        {"$select", "id,subject,from,toRecipients,receivedDateTime,body,bodyPreview,hasAttachments"}
      ]
    ]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        {:ok, %{"message" => normalise_message(body)}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_message(m) do
    %{
      "id"             => m["id"],
      "subject"        => m["subject"],
      "from"           => get_in(m, ["from", "emailAddress", "address"]),
      "to"             => Enum.map(m["toRecipients"] || [],
                            fn r -> get_in(r, ["emailAddress", "address"]) end),
      "received_at"    => m["receivedDateTime"],
      "body"           => get_in(m, ["body", "content"]),
      "body_type"      => get_in(m, ["body", "contentType"]),
      "snippet"        => m["bodyPreview"],
      "has_attachments" => m["hasAttachments"],
      "attachments"    => Enum.map(m["attachments"] || [], &normalise_attachment/1)
    }
  end

  defp normalise_attachment(a) do
    %{
      "id"           => a["id"],
      "name"         => a["name"],
      "content_type" => a["contentType"],
      "size"         => a["size"]
    }
  end

  # ─── mail.move_to_folder — POST /me/messages/{id}/move ────────────────
  # vendor: POST /v1.0/me/messages/{id}/move  body: {"destinationId":"<id>"}
  # docs:   https://learn.microsoft.com/graph/api/message-move
  # Graph returns the moved message — we only need the new id.

  defp mail_move_to_folder(args, ctx) do
    message_id     = Helpers.safe_path_id(args["message_id"])
    destination_id = Helpers.safe_path_id(args["destination_folder_id"])

    url  = "#{@graph_base}/messages/#{message_id}/move"
    body = %{"destinationId" => destination_id}

    case RestBridge.raw_request(:post, Helpers.with_bearer([url: url, json: body], ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        {:ok, %{"message_id" => body["id"] || message_id}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end
end
