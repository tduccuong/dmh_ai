# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.LookupCredential do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Credentials

  @impl true
  def name, do: "lookup_credential"

  @impl true
  def description do
    """
    Fetch a previously-saved credential for the current user by target. If target is omitted, returns the list of saved targets (labels + types, no secrets) so you can pick the right one. Always prefer lookup_credential before asking the user — they may have given you this credential on a prior turn.
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
            description: "Exact target label previously used with save_credential. Omit to list all saved targets (metadata only)."
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
          nil  -> {:ok, %{found: false, target: args["target"]}}
          cred -> {:ok, %{found: true, target: cred.target, cred_type: cred.cred_type,
                           payload: cred.payload, notes: cred.notes}}
        end

      true ->
        {:ok, %{targets: Credentials.list(user_id)}}
    end
  end
end
