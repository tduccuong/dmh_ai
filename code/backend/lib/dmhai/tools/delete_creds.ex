# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.DeleteCreds do
  @moduledoc """
  Delete a saved credential by `target`. Same primitive for any kind
  the user wants to forget: ad-hoc passwords, SSH keys, API keys,
  OAuth tokens, MCP-server tokens.

  When `target` matches the `mcp:<canonical>` shape the cascade
  fires:

    1. Decode the credential's `asm_json`. If it carries a
       `revocation_endpoint` (RFC 7009), POST the access token (and
       refresh token if present) so the AS invalidates them
       server-side. Best-effort — a 4xx, 5xx, or transport error
       does not block the local cleanup.
    2. Drop the matching `authorized_services` row and every
       `task_services` attachment for that alias (`MCP.Registry.deauthorize/2`).
    3. Delete the credential row.

  For non-`mcp:` targets, only step 3 fires.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Auth.Credentials
  alias Dmhai.MCP.Registry

  require Logger

  @http_timeout_ms 10_000

  @impl true
  def name, do: "delete_creds"

  @impl true
  def description do
    """
    Remove a saved credential by `target`. Only on explicit user request. For `mcp:<canonical>` targets, also disconnects the service: revokes at the AS (RFC 7009, best-effort), drops the authorized row, detaches every task holding it.
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
      cascade_result = maybe_mcp_cascade(user_id, target)
      Credentials.delete(user_id, target)

      {:ok,
       Map.merge(%{deleted: true, target: target}, cascade_result)}
    end
  end

  def execute(_, _), do: {:error, "required arg: target (string)"}

  # ── private ───────────────────────────────────────────────────────────

  # If the target is an MCP credential (`mcp:<canonical>`), best-effort
  # revoke at the AS, then drop the authorized_services row and every
  # task_services attachment. Returns a small map summarising what
  # happened so the model can report it cleanly back to the user.
  defp maybe_mcp_cascade(user_id, "mcp:" <> canonical) do
    case Credentials.lookup(user_id, "mcp:" <> canonical) do
      nil ->
        # No credential to revoke; `deauthorize` is still safe to run
        # (it no-ops on a missing row but also drops orphaned task
        # attachments if any).
        Registry.deauthorize(user_id, lookup_alias_or_unknown(user_id, canonical))
        %{disconnected: true, revoked: false, revoke_reason: "no credential row to revoke"}

      cred ->
        revoke_outcome = best_effort_revoke(cred)
        alias_ = cred.payload["alias"] || lookup_alias_or_unknown(user_id, canonical)
        Registry.deauthorize(user_id, alias_)
        Map.merge(%{disconnected: true, alias: alias_}, revoke_outcome)
    end
  end
  defp maybe_mcp_cascade(_user_id, _target), do: %{}

  defp lookup_alias_or_unknown(user_id, canonical) do
    case Registry.find_authorized_by_resource(user_id, canonical) do
      %{alias: a} -> a
      _           -> "unknown"
    end
  end

  # POST `{token, token_type_hint}` to `revocation_endpoint` per
  # RFC 7009. Best-effort: a non-2xx response or a transport error is
  # logged but does NOT block the local cleanup — the user's expressed
  # intent is "delete the local copy"; AS-side cleanup is a courtesy.
  defp best_effort_revoke(%{kind: "oauth2_mcp", payload: payload}) do
    asm = decode_asm(payload["asm_json"])
    rev_endpoint = asm[:revocation_endpoint]
    access_token = payload["access_token"]

    cond do
      not is_binary(rev_endpoint) or rev_endpoint == "" ->
        %{revoked: false, revoke_reason: "AS does not advertise revocation_endpoint"}

      not is_binary(access_token) or access_token == "" ->
        %{revoked: false, revoke_reason: "credential has no access_token to revoke"}

      true ->
        do_revoke(rev_endpoint, payload, access_token)
    end
  end

  defp best_effort_revoke(%{kind: kind}) do
    %{revoked: false, revoke_reason: "kind=#{kind} doesn't support revocation"}
  end

  defp do_revoke(endpoint, payload, access_token) do
    body =
      [
        {"token",           access_token},
        {"token_type_hint", "access_token"}
      ] ++ maybe_client_credentials(payload)

    case Req.post(endpoint,
           form: body,
           headers: [{"accept", "application/json"}],
           receive_timeout: @http_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        %{revoked: true}

      {:ok, %{status: status}} ->
        Logger.info("[DeleteCreds] revoke non-2xx status=#{status} endpoint=#{endpoint}")
        %{revoked: false, revoke_reason: "AS returned status #{status}"}

      {:error, reason} ->
        Logger.info("[DeleteCreds] revoke transport error: #{inspect(reason)}")
        %{revoked: false, revoke_reason: "transport error during revocation"}
    end
  rescue
    e ->
      Logger.error("[DeleteCreds] revoke raised: #{Exception.message(e)}")
      %{revoked: false, revoke_reason: "exception during revocation"}
  end

  defp maybe_client_credentials(payload) do
    cid = payload["client_id"]
    csec = payload["client_secret"]

    base = if is_binary(cid) and cid != "", do: [{"client_id", cid}], else: []

    if is_binary(csec) and csec != "", do: base ++ [{"client_secret", csec}], else: base
  end

  defp decode_asm(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} -> Map.new(m, fn {k, v} -> {String.to_atom(k), v} end)
      _        -> %{}
    end
  end
  defp decode_asm(_), do: %{}
end
