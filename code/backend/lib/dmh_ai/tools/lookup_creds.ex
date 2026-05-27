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

    Credentials workflow (three primitives — `save_creds(target, kind, payload, notes?, expires_at?)`, `lookup_creds(target?)`, `delete_creds(target)`). `target` is a stable specific label (host+user, service name) — reuse across saves + lookups. Never generic (`"ssh"`, `"password"`).

    When you need auth:
    1. In-context first — visible in this chain's messages? Use directly.
    2. Else `lookup_creds(target: "<label>")` — user may have saved it earlier. Result has `is_expired`; refresh via provider helper if available, else ask.
    3. `found: false` → ask. Single-field → plain text. Multi-field (≥2 inputs) → `request_input`.
    4. Save immediately via `save_creds(target, kind, payload)` so future chains don't re-ask.

    `delete_creds` only on explicit user request.

    Failure at use-time — any access failure on a previously-working credential (`Permission denied`, HTTP 401/403, "token expired", "key rejected", "method not found", "scope insufficient"): a setup helper reporting `ready`/`authorized`/`connected` proves the LOCAL credential is intact; it does NOT prove the REMOTE side still accepts it. The remote may have rotated keys, revoked the grant, narrowed scope, or never received the install in the first place. Diagnose before declaring the resource blocked:
      - Re-invoke the setup helper (`provision_ssh_identity`, `authorize_service`, `connect_mcp`) to re-emit install / consent hints — the helper's setup output is the most authoritative way to restore access.
      - Probe the access in verbose / diagnostic mode (`ssh -v`, `curl -v`, a parallel call with an alternate auth header) to see WHAT was rejected and WHY.
      - Try an alternate auth method when the tool exposes one (`-o PreferredAuthentications=publickey,keyboard-interactive`, `Authorization: Bearer` vs query-param token).
    Only after these diagnostic probes is "the credential is broken on the remote side" an earned conclusion. Then surface the concrete step-by-step setup the user needs to perform (the same shape `needs_setup` produces).

    Authenticated REST APIs (OAuth-protected services that aren't MCP — the common case for popular services with native APIs the operator has wired up):

    1. Resolve the API URL. Cascade: training → `fetch_index` → `web_search` → ask. Never invent URLs from service names.
    2. Try `lookup_creds(target: "oauth:<slug>")` first. Credential targets are slug-keyed (`oauth:google_workspace`, `oauth:hubspot`). When fresh token(s) exist, use them directly: `run_script` with curl + `Authorization: Bearer $access_token`.
    3. No token in lookup_creds → call `authorize_service(target: <slug>)`. The runtime resolves the input against the catalog (slug, host, full URL, partial name — all accepted). If matched, you get `{status: "needs_auth", auth_url}` — relay the auth_url as a clickable link, end the chain. The OAuth callback auto-resumes the chain after the user authorizes; on the next turn `lookup_creds` returns a fresh token.
    4. `authorize_service` returns `{:error, ...}` when the input is ambiguous OR not configured. The error names the closest configured services. Tell the USER what the runtime suggested and ask them to pick a slug OR give a URL — do NOT guess and retry. If nothing close fits, the service isn't wired up here; offer fallbacks (`web_search`, honest decline). Never ask the user for OAuth endpoints or client secrets — operators set those up, not users.
    5. 401 mid-call — copy the credential's `auth_target` into `authorize_service(target: <auth_target>, force_new: true)`, then `lookup_creds` again and retry. The cred's own `target` field is the vault key (`oauth:<slug>`), not the catalog handle.
    6. User asks to ADD a new account ("add my new X account", "connect another X account") — `authorize_service(target: <auth_target-or-slug>, force_new: true)`. Without `force_new` the tool short-circuits to `authorized` on the first existing row.

    Never invent OAuth endpoints from a service's brand name. The catalog is the only source of truth for which services this deployment can authorize.

    Multi-account fan-out: `lookup_creds` returns `credentials: [...]` — an array, ALWAYS. When the array has more than one entry, the user has authorized this service from multiple accounts; unless the user named one specifically in their ask, perform the requested action against EACH account in parallel and merge the results in your final reply. Attribute each section to its account so the user can tell which row produced which output. When the user does name an account, pass `account: "<account>"` on the next `lookup_creds` to filter to that single entry. Single-entry arrays use the one credential — no fan-out logic needed.
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
