# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Drive do
  @moduledoc """
  Google Drive surface — `drive.list`, `drive.upload`, `drive.download`,
  `drive.create_folder`.
  """

  alias DmhAi.Connectors.MCPServer.{ErrorMap, RestBridge, FunctionSpec}
  alias DmhAi.Connectors.GoogleWorkspace.MCPHandler.Helpers

  @drive_base   "https://www.googleapis.com/drive/v3"
  @drive_upload "https://www.googleapis.com/upload/drive/v3"

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
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
      },
      "drive.download" => %FunctionSpec{
        handler: &drive_download/2,
        doc:     "Download a stored Drive file's bytes (text/* → string; other MIME → base64)."
      },
      "drive.create_folder" => %FunctionSpec{
        method:  :post,
        url:     "#{@drive_base}/files",
        request: &drive_create_folder_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"folder_id" => body["id"], "name" => body["name"]}}
                  end,
        doc:     "Create a Drive folder under root or a given parent."
      }
    }
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

  # ─── drive.download — GET /files/{id}?alt=media ───────────────────────

  # vendor: GET /drive/v3/files/{id}?alt=media
  # docs:   https://developers.google.com/drive/api/reference/rest/v3/files/get
  # Plain stored files only. Native Docs / Sheets / Slides
  # (`application/vnd.google-apps.*`) need `files/{id}/export` and
  # are NOT handled here — surfacing a clear caveat is better than
  # silently empty content.
  defp drive_download(args, ctx) do
    file_id = Helpers.safe_path_id(args["file_id"])
    url     = "#{@drive_base}/files/#{file_id}"

    opts = [url: url, params: [{"alt", "media"}]]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {content, mime} = encode_download_body(body)
        {:ok, %{"content" => content, "content_type" => mime}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp encode_download_body(body) when is_binary(body) do
    if String.valid?(body) and String.printable?(body) do
      {body, "text/plain"}
    else
      {Base.encode64(body), "application/octet-stream"}
    end
  end

  defp encode_download_body(body) when is_map(body) do
    # Drive's `alt=media` returns binary for stored files; a map
    # response usually means an error envelope leaked through 2xx
    # (rare). Surface verbatim as JSON.
    {Jason.encode!(body), "application/json"}
  end

  defp encode_download_body(other), do: {to_string(other), "text/plain"}

  # ─── drive.create_folder — files.create with folder mime type ─────────

  # vendor: POST /drive/v3/files
  # docs:   https://developers.google.com/drive/api/reference/rest/v3/files/create
  defp drive_create_folder_request(args, _ctx) do
    name = args["name"]

    body =
      %{"name" => name, "mimeType" => "application/vnd.google-apps.folder"}
      |> maybe_put_parents(Map.get(args, "parent_id"))

    [json: body]
  end

  defp maybe_put_parents(map, nil), do: map
  defp maybe_put_parents(map, ""),  do: map
  defp maybe_put_parents(map, parent_id) when is_binary(parent_id) do
    Map.put(map, "parents", [Helpers.safe_path_id(parent_id)])
  end
end
