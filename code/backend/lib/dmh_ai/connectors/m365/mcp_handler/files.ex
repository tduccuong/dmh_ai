# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Files do
  @moduledoc """
  OneDrive Files surface — `files.list`, `files.upload`,
  `files.download`. `files.upload` uses Graph's small-file PUT path
  (raw bytes + per-filename URL template); `files.download` text/*
  content passes through as a string while binary content is
  base64-encoded so the model can still reference / forward it
  through a string envelope.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers

  @graph_base Helpers.graph_base()

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "files.list" => %FunctionSpec{
        handler: &files_list/2,
        doc:     "List OneDrive children at root or under a path."
      },
      "files.upload" => %FunctionSpec{
        handler: &files_upload/2,
        doc:     "Upload a small (<4 MB) file to OneDrive root by name."
      },
      "files.download" => %FunctionSpec{
        handler: &files_download/2,
        doc:     "Download a OneDrive item's content (text passes through, binary base64-encoded)."
      }
    }
  end

  # ─── files.list — root or path ────────────────────────────────────────

  # vendor: GET /v1.0/me/drive/root/children       (root)
  # vendor: GET /v1.0/me/drive/root:/<path>:/children
  defp files_list(args, ctx) do
    path  = Map.get(args, "path", "") |> to_string() |> String.trim()
    limit = Map.get(args, "limit", 25)

    url =
      case path do
        "" -> "#{@graph_base}/drive/root/children"
        _  -> "#{@graph_base}/drive/root:/#{URI.encode(path)}:/children"
      end

    opts = [url: url, params: [{"$top", limit}, {"$select", "id,name,size,file,folder,lastModifiedDateTime"}]]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => items}} when is_list(items) ->
        flat = Enum.map(items, &normalise_drive_item/1)
        {:ok, %{"items" => flat}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_drive_item(item) do
    %{
      "id"            => item["id"],
      "name"          => item["name"],
      "size"          => item["size"],
      "kind"          => cond do
        Map.has_key?(item, "folder") -> "folder"
        Map.has_key?(item, "file")   -> "file"
        true                          -> "unknown"
      end,
      "last_modified" => item["lastModifiedDateTime"]
    }
  end

  # ─── files.upload — PUT raw bytes to /root:/<name>:/content ───────────

  defp files_upload(args, ctx) do
    name      = args["name"]
    content   = args["content"] || ""
    mime_type = Map.get(args, "mime_type", "application/octet-stream")

    url = "#{@graph_base}/drive/root:/#{URI.encode(name)}:/content"

    opts = [
      url:     url,
      body:    content,
      headers: [{"content-type", mime_type}]
    ]

    case RestBridge.raw_request(:put, Helpers.with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, %{"file_id" => body["id"], "name" => body["name"], "web_url" => body["webUrl"]}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  # ─── files.download — GET /me/drive/items/{id}/content ────────────────
  # vendor: GET /v1.0/me/drive/items/{id}/content
  # docs:   https://learn.microsoft.com/graph/api/driveitem-get-content
  # text/* content passes through as a string; binary content is
  # base64-encoded so the model can still reference / forward it
  # through a string envelope. Larger-than-context files are an
  # operator concern (no automatic chunking here).

  defp files_download(args, ctx) do
    file_id = Helpers.safe_path_id(args["file_id"])
    url     = "#{@graph_base}/drive/items/#{file_id}/content"

    case RestBridge.raw_request(:get, Helpers.with_bearer([url: url], ctx)) do
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
    if String.valid?(body) and printable?(body) do
      {body, "text/plain"}
    else
      {Base.encode64(body), "application/octet-stream"}
    end
  end

  defp encode_download_body(body) when is_map(body) do
    # Graph occasionally returns JSON metadata when a follow-up
    # download link is required; surface it verbatim so the agent
    # can decide what to do next.
    {Jason.encode!(body), "application/json"}
  end

  defp encode_download_body(other), do: {to_string(other), "text/plain"}

  defp printable?(s),
    do: String.printable?(s) or String.printable?(s, 0)
end
