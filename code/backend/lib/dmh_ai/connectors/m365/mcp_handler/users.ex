# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Users do
  @moduledoc """
  Microsoft Graph directory users surface — `user.find_by_email`.
  Identity pivot used by other surfaces to resolve an email to a
  Graph user object id.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers

  @graph_root Helpers.graph_root()

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "user.find_by_email" => %FunctionSpec{
        handler: &user_find_by_email/2,
        doc:     "Look up a directory user by email (Graph GET /users/{email}). Identity pivot."
      }
    }
  end

  # ─── user.find_by_email — GET /users/{email} ─────────────────────────
  # vendor: GET /v1.0/users/{email}
  # docs:   https://learn.microsoft.com/graph/api/user-get
  # Graph accepts the userPrincipalName (= email for most tenants)
  # directly as the path id. The whole user resource is surfaced as
  # `%{"user" => body}` so downstream `{{N.user.id}}` references
  # pick up the Graph user object id.

  defp user_find_by_email(args, ctx) do
    email = Helpers.safe_path_id(args["email"])
    url   = "#{@graph_root}/users/#{email}"

    case RestBridge.raw_request(:get, Helpers.with_bearer([url: url], ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        {:ok, %{"user" => body}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end
end
