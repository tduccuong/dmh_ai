# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Contacts do
  @moduledoc """
  Outlook Contacts surface — `contacts.search`.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers

  @graph_base Helpers.graph_base()

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "contacts.search" => %FunctionSpec{
        handler: &contacts_search/2,
        doc:     "Search the user's Outlook contacts; returns name + email pairs."
      }
    }
  end

  # ─── contacts.search — $search KQL ────────────────────────────────────

  defp contacts_search(args, ctx) do
    q     = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 10)

    opts = [
      url:     "#{@graph_base}/contacts",
      params:  [{"$search", "\"#{q}\""}, {"$top", limit},
                {"$select", "id,displayName,emailAddresses"}],
      headers: [{"consistencylevel", "eventual"}]
    ]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => contacts}} when is_list(contacts) ->
        flat =
          Enum.map(contacts, fn c ->
            %{
              "name"  => c["displayName"],
              "email" => get_in(c, ["emailAddresses", Access.at(0), "address"])
            }
          end)

        {:ok, %{"contacts" => flat}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end
end
