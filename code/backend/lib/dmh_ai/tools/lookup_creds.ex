# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.LookupCreds do
  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Auth.{Credentials, OAuth2}

  @impl true
  def name, do: "lookup_creds"

  @impl true
  def description do
    """
    Fetch saved credential(s) for a target. Returns an ARRAY shape:
    `{found, target, credentials: [{account, kind, payload, expires_at, is_expired, notes, auth_target?}, ...]}`. Multiple entries mean the user has authorized this service from multiple accounts.

    When `credentials` has more than one entry AND the user did not name a specific account in their ask, perform the requested action against EACH account in parallel and merge the results in your final reply, attributing each section to its account. Use the optional `account` arg to filter to a single entry once the user picks one (or for follow-up turns where the user named an account).

    Each entry may carry `auth_target` — the stable handle to pass to the credential's lifecycle tool when re-auth is needed (e.g. a stored OAuth token gets HTTP 401 mid-call). Copy `auth_target` verbatim into `authorize_service(target: <auth_target>)`; do NOT re-derive the auth identifier from the credential `target` string (it carries a vault namespace prefix the catalog doesn't recognise).

    Without `target`: returns the metadata list of every saved credential — one row per (target, account) tuple — so you can choose which to fetch in detail.
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
            description: "Exact target label (e.g. `oauth:google_workspace`, `oauth:hubspot`, `mcp:<canonical>`, or a free-form label previously used with save_creds). OAuth targets are slug-keyed — see `<authorized_services>` for the valid slugs. Omit to list every saved (target, account) pair without payloads."
          },
          account: %{
            type: "string",
            description: "Optional account label. For OAuth: the email/login the provider returned. For `ssh:<host>` targets: the remote login (e.g. `cuong`, `root`). Omit to fetch every account for the target. Provide when the user named one or when a previous lookup result narrowed to a single choice."
          }
        },
        required: []
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id = ctx[:user_id] || ctx["user_id"]
    target  = trim_or_nil(args["target"])
    account = trim_or_nil(args["account"])

    cond do
      is_nil(user_id) or user_id == "" ->
        {:error, "no user_id in context"}

      is_binary(target) ->
        creds = OAuth2.lookup_all_with_refresh(user_id, target)
        creds = if is_binary(account), do: Enum.filter(creds, &(&1.account == account)), else: creds
        {:ok, build_target_result(target, account, creds)}

      true ->
        {:ok, %{targets: Credentials.list(user_id)}}
    end
  end

  # ── private ──────────────────────────────────────────────────────────

  defp build_target_result(target, _account, []) do
    %{found: false, target: target, credentials: []}
  end

  defp build_target_result(target, _account, creds) when is_list(creds) do
    %{
      found:       true,
      target:      target,
      credentials: Enum.map(creds, &cred_to_entry/1)
    }
  end

  defp cred_to_entry(cred) do
    base = %{
      account:    cred.account,
      kind:       cred.kind,
      payload:    cred.payload,
      notes:      cred.notes,
      expires_at: cred.expires_at,
      is_expired: cred.is_expired
    }

    base =
      case auth_target_for(cred) do
        nil    -> base
        target -> Map.put(base, :auth_target, target)
      end

    case Map.get(cred, :refresh_error) do
      nil   -> base
      reason -> Map.put(base, :refresh_error, reason)
    end
  end

  # Stable handle the model copies into the credential's lifecycle
  # tool when re-auth is needed (e.g. a 401 mid-call). See
  # arch_wiki/dmh_ai/integrations.md §`auth_target`. Reads from
  # payload.auth_target, populated at credential write time.
  # Pre-#231 rows without the field are nil — operator runs the
  # one-shot backfill SQL to populate them.
  defp auth_target_for(%{payload: %{} = payload}) do
    case Map.get(payload, "auth_target") do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp auth_target_for(_), do: nil

  defp trim_or_nil(s) when is_binary(s) do
    case String.trim(s) do
      ""    -> nil
      v     -> v
    end
  end
  defp trim_or_nil(_), do: nil
end
