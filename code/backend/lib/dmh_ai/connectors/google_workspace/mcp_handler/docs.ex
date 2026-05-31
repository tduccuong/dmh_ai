# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Docs do
  @moduledoc """
  Google Docs surface — `docs.read_text`.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.GoogleWorkspace.MCPHandler.Helpers

  @docs_base "https://docs.googleapis.com/v1"

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "docs.read_text" => %FunctionSpec{
        handler: &docs_read_text/2,
        doc:     "Read a Google Doc's text content (concatenated body paragraphs)."
      }
    }
  end

  # ─── docs.read_text — GET doc + concatenate body paragraphs ───────────

  defp docs_read_text(args, ctx) do
    document_id = args["document_id"]
    url = "#{@docs_base}/documents/#{URI.encode(document_id)}"

    case RestBridge.raw_request(:get, Helpers.with_bearer([url: url], ctx)) do
      {:ok, status, body} when status in 200..299 ->
        text =
          body
          |> get_in(["body", "content"])
          |> Kernel.||([])
          |> Enum.flat_map(&extract_paragraph_text/1)
          |> Enum.join("\n")

        {:ok, %{"title" => body["title"], "text" => text}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp extract_paragraph_text(%{"paragraph" => %{"elements" => elems}}) when is_list(elems) do
    elems
    |> Enum.map(fn e -> get_in(e, ["textRun", "content"]) end)
    |> Enum.reject(&is_nil/1)
  end
  defp extract_paragraph_text(_), do: []
end
