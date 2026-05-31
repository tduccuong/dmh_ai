# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Gmail.Mime do
  @moduledoc """
  MIME compose / parse helpers used by `gmail.send`, `gmail.reply`,
  `gmail.create_draft` and the `gmail.read` response normaliser. All
  text bodies are RFC-2822 plain-text; no multipart authoring.
  """

  @doc """
  Header lookup against Gmail's `payload.headers` shape (a list of
  `%{"name" => …, "value" => …}` maps). Returns `""` when missing
  so downstream string interpolation never crashes.
  """
  def header(headers, name) do
    Enum.find_value(headers, "", fn
      %{"name" => ^name, "value" => v} -> v
      _ -> nil
    end)
  end

  @doc """
  Compose a plain-text RFC-2822 message body (To / Subject / MIME /
  Content-Type headers + body).
  """
  def compose_text(to, subject, body) do
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

  @doc """
  Compose a plain-text reply MIME with `In-Reply-To` / `References`
  headers when an `in_reply_to_message_id` is supplied.
  """
  def compose_reply(to, subject, in_reply_to_message_id, body) do
    headers = [
      "To: ", to, "\r\n",
      "Subject: ", subject, "\r\n"
    ]

    in_reply_to =
      case in_reply_to_message_id do
        s when is_binary(s) and s != "" ->
          [
            "In-Reply-To: <", s, ">\r\n",
            "References: <",  s, ">\r\n"
          ]
        _ -> []
      end

    (headers ++ in_reply_to ++
     [
       "MIME-Version: 1.0\r\n",
       "Content-Type: text/plain; charset=UTF-8\r\n",
       "\r\n",
       body || ""
     ])
    |> IO.iodata_to_binary()
  end

  @doc """
  Walk a Gmail message payload tree and concatenate any decoded
  `text/plain` bodies; ignores attachments. Returns `""` for
  payloads without any text body.
  """
  def extract_body(nil), do: ""
  def extract_body(%{"mimeType" => "text/plain", "body" => %{"data" => data}}) when is_binary(data),
    do: decode_b64url(data)
  def extract_body(%{"parts" => parts}) when is_list(parts) do
    parts
    |> Enum.map(&extract_body/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end
  def extract_body(_), do: ""

  defp decode_b64url(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> bin
      :error     -> ""
    end
  end

  @doc """
  Walk a Gmail message payload tree and surface every attachment as
  `%{name, attachment_id, content_type, size}` maps. Returns `[]`
  for payloads without attachments.
  """
  def extract_attachments(nil), do: []
  def extract_attachments(%{"parts" => parts}) when is_list(parts) do
    parts
    |> Enum.flat_map(fn part ->
      case part do
        %{"filename" => fname, "body" => %{"attachmentId" => aid, "size" => size}}
            when is_binary(fname) and fname != "" ->
          [%{
            "name"         => fname,
            "attachment_id" => aid,
            "content_type" => Map.get(part, "mimeType"),
            "size"         => size
          }]

        %{"parts" => _} ->
          extract_attachments(part)

        _ ->
          []
      end
    end)
  end
  def extract_attachments(_), do: []
end
