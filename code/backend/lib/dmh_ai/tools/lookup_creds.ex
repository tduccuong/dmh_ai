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
    Fetch saved credential(s) by target. Returns `{found, target, credentials: [{account, kind, payload, expires_at, is_expired, notes, auth_target?}, ...]}` — `credentials` is ALWAYS an array.

    Multi-account fan-out: when the array has more than one entry and the user did not name a specific account, run the requested action against EACH credential in parallel and attribute each section in the final reply. When the user names an account, pass `account: "<name>"` to filter to that one entry.

    `auth_target` (when present) is the stable handle to copy into `authorize_service(target: <auth_target>, force_new: true)` for re-auth on HTTP 401 / scope-insufficient errors. The cred's own `target` carries a vault prefix — use `auth_target` for lifecycle calls, never the bare target.

    Targets are slug-keyed for OAuth (`oauth:<slug>`) and free-form for `save_creds`-stored secrets. Omit `target` to list every saved (target, account) pair without payloads.

    Auth flow when a chain needs a credential: try `lookup_creds(target: "<label>")` → if `found: false` (or `is_expired` and no refresh helper succeeds) call `authorize_service(target: <slug>)` or ask the user for the missing field via `request_input`. After saving via `save_creds`, never repeat the ask in future chains.
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
            description: "Exact target label. OAuth targets are slug-keyed as `oauth:<slug>` (the slug from `<authorized_services>`); MCP targets as `mcp:<canonical>`; or a free-form label previously used with `save_creds`. Omit to list every saved (target, account) pair without payloads."
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
