# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.OneNote do
  @moduledoc """
  OneNote surface — `onenote.read_page`. Graph returns text/html for
  page content; we strip HTML tags for the agent (the full HTML is
  rarely useful and inflates the model's context).
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers

  @graph_base Helpers.graph_base()

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "onenote.read_page" => %FunctionSpec{
        handler: &onenote_read_page/2,
        doc:     "Read a OneNote page's text content (HTML stripped to plain text)."
      }
    }
  end

  # ─── onenote.read_page — GET /me/onenote/pages/{id}/content ───────────

  defp onenote_read_page(args, ctx) do
    page_id = args["page_id"]
    url = "#{@graph_base}/onenote/pages/#{URI.encode(page_id)}/content"

    case RestBridge.raw_request(:get, Helpers.with_bearer([url: url, accept: "text/html"], ctx)) do
      {:ok, status, html} when status in 200..299 and is_binary(html) ->
        text = strip_html_to_text(html)
        {:ok, %{"text" => text, "title" => "OneNote page"}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp strip_html_to_text(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
  defp strip_html_to_text(_), do: ""
end
