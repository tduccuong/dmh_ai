# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.SaveCreds do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Auth.Credentials

  @impl true
  def name, do: "save_creds"

  @impl true
  def description do
    """
    Persist a credential the user just provided. `target` is a stable, specific label (host+user, service name) — reuse it across saves + lookups for cross-chain recall. `kind` describes `payload`'s shape ("ssh_key", "user_pass", "api_key", "oauth2", …). Set `expires_at` (unix ms) for time-bounded creds (OAuth2 access tokens); omit for static.
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
            description: "Stable, specific label for who/what this credential unlocks. Reuse across saves + lookups."
          },
          kind: %{
            type: "string",
            description: "Free-form label describing `payload`'s shape (e.g. 'ssh_key', 'user_pass', 'api_key', 'oauth2'). Pick a stable name and reuse it for that class of credential."
          },
          payload: %{
            type: "object",
            description: "JSON object holding the secret(s). Shape determined by `kind`: ssh_key → {username, private_key}; user_pass → {username, password}; api_key → {value}; oauth2 → {access_token, refresh_token?, scope?, token_type?}."
          },
          notes: %{
            type: "string",
            description: "Optional one-line note on when / why to use this credential."
          },
          expires_at: %{
            type: "integer",
            description: "Optional unix ms expiry. Populate for time-bounded creds (OAuth2 access tokens); omit for static creds."
          }
        },
        required: ["target", "kind", "payload"]
      }
    }
  end

  @impl true
  def execute(%{"target" => target, "kind" => kind, "payload" => payload} = args, ctx)
      when is_binary(target) and is_binary(kind) and is_map(payload) do
    user_id = ctx[:user_id] || ctx["user_id"]

    if is_nil(user_id) or user_id == "" do
      {:error, "no user_id in context"}
    else
      Credentials.save(user_id, target, kind, payload,
        notes:      Map.get(args, "notes"),
        expires_at: Map.get(args, "expires_at")
      )
      {:ok, %{saved: true, target: target, kind: kind}}
    end
  end

  def execute(_, _), do: {:error, "required args: target (string), kind (string), payload (object)"}
end
