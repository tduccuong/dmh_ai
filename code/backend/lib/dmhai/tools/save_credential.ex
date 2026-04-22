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
    Persist a credential (ssh key, user+password, API key, token) the user just provided, scoped to (user, target). On the next turn or future session you can fetch it back with lookup_credential. Target is your choice of stable label, e.g. "pi@192.168.178.22", "github-api", "aws-prod". Payload is a JSON object whose shape depends on cred_type.
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
            description: "Free-form stable label identifying who/what this credential unlocks. e.g. \"pi@192.168.178.22\", \"github-api\", \"openai\"."
          },
          cred_type: %{
            type: "string",
            enum: ["ssh_key", "user_pass", "api_key", "token", "other"],
            description: "Kind of credential. ssh_key: private key text. user_pass: username+password. api_key / token: single secret string. other: anything else."
          },
          payload: %{
            type: "object",
            description: "JSON object holding the secret(s). Typical shapes: ssh_key → {\"username\": \"pi\", \"private_key\": \"-----BEGIN …\"}. user_pass → {\"username\": \"cuong\", \"password\": \"…\"}. api_key / token → {\"value\": \"sk-…\"}."
          },
          notes: %{
            type: "string",
            description: "Optional one-line note on when/why to use this credential. e.g. \"home raspberry pi, sudo enabled\"."
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
