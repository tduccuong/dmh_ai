# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.DeleteCreds do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Auth.Credentials

  @impl true
  def name, do: "delete_creds"

  @impl true
  def description do
    """
    Remove a saved credential by target. Use ONLY on explicit user request ("forget my password for X", "remove the saved key for Y"). Don't auto-delete on lookup misses — `is_expired=true` from `lookup_creds` is a refresh signal, not a delete signal.
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
            description: "Exact target label of the credential to delete."
          }
        },
        required: ["target"]
      }
    }
  end

  @impl true
  def execute(%{"target" => target}, ctx) when is_binary(target) and target != "" do
    user_id = ctx[:user_id] || ctx["user_id"]

    if is_nil(user_id) or user_id == "" do
      {:error, "no user_id in context"}
    else
      Credentials.delete(user_id, target)
      {:ok, %{deleted: true, target: target}}
    end
  end

  def execute(_, _), do: {:error, "required arg: target (string)"}
end
