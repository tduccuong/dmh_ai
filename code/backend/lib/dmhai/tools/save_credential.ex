# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.SaveCredential do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Credentials

  @impl true
  def name, do: "save_credential"

  @impl true
  def description do
    """
    Persist a credential (ssh key, user+password, API key, token) the user just provided, scoped to (user, target). Fetch back later with lookup_credential. Target is a stable, specific label (host+user, service name, API name). Payload is a JSON object whose shape depends on cred_type.
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
            description: "Stable, specific label for who/what this credential unlocks. Reuse the same label across saves + lookups."
          },
          cred_type: %{
            type: "string",
            enum: ["ssh_key", "user_pass", "api_key", "token", "other"],
            description: "ssh_key → private key text; user_pass → username+password; api_key / token → single secret string; other → anything else."
          },
          payload: %{
            type: "object",
            description: "JSON object holding the secret(s). Shape by cred_type: ssh_key → {username, private_key}; user_pass → {username, password}; api_key / token → {value}."
          },
          notes: %{
            type: "string",
            description: "Optional one-line note on when / why to use this credential."
          }
        },
        required: ["target", "cred_type", "payload"]
      }
    }
  end

  @impl true
  def execute(%{"target" => target, "cred_type" => cred_type, "payload" => payload} = args, ctx)
      when is_binary(target) and is_binary(cred_type) and is_map(payload) do
    notes = Map.get(args, "notes")
    user_id = ctx[:user_id] || ctx["user_id"]

    if is_nil(user_id) or user_id == "" do
      {:error, "no user_id in context"}
    else
      Credentials.save(user_id, target, cred_type, payload, notes)
      {:ok, %{saved: true, target: target, cred_type: cred_type}}
    end
  end

  def execute(_, _), do: {:error, "required args: target (string), cred_type (string), payload (object)"}
end
