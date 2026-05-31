# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Contacts do
  @moduledoc """
  Google People (Contacts) surface — `contacts.search`.
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec

  @people_base "https://people.googleapis.com/v1"

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "contacts.search" => %FunctionSpec{
        method:  :get,
        url:     "#{@people_base}/people:searchContacts",
        request: fn args, _ctx ->
          [params: [
            {"query",    Map.get(args, "query", "")},
            {"readMask", "names,emailAddresses"},
            {"pageSize", Map.get(args, "limit", 10)}
          ]]
        end,
        response: fn s, body when s in 200..299 ->
                    contacts =
                      Map.get(body, "results", [])
                      |> Enum.map(fn %{"person" => p} -> normalise_contact(p) end)

                    {:ok, %{"contacts" => contacts}}
                  end,
        doc: "Search the user's contacts by query string; returns name + email."
      }
    }
  end

  defp normalise_contact(person) do
    %{
      "name"  => get_in(person, ["names", Access.at(0), "displayName"]),
      "email" => get_in(person, ["emailAddresses", Access.at(0), "value"])
    }
  end
end
