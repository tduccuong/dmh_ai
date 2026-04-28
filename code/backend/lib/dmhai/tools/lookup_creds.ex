# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.LookupCreds do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Auth.Credentials

  @impl true
  def name, do: "lookup_creds"

  @impl true
  def description do
    """
    Fetch a previously-saved credential. With `target`: returns `{found, kind, payload, expires_at, is_expired, notes}`. Without `target`: returns the list of saved targets (metadata only).
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          target: %{
            type: "string",
            description: "Exact target label previously used with save_creds. Omit to list all saved targets (metadata only)."
          }
        },
        required: []
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id = ctx[:user_id] || ctx["user_id"]

    cond do
      is_nil(user_id) or user_id == "" ->
        {:error, "no user_id in context"}

      is_binary(args["target"]) and args["target"] != "" ->
        case Credentials.lookup(user_id, args["target"]) do
          nil ->
            {:ok, %{found: false, target: args["target"]}}

          cred ->
            {:ok,
             %{
               found:      true,
               target:     cred.target,
               kind:       cred.kind,
               payload:    cred.payload,
               notes:      cred.notes,
               expires_at: cred.expires_at,
               is_expired: cred.is_expired
             }}
        end

      true ->
        {:ok, %{targets: Credentials.list(user_id)}}
    end
  end
end
