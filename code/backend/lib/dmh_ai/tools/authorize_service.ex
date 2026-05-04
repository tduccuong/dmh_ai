# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.AuthorizeService do
  @moduledoc """
  Authorize the current user against an OAuth-protected REST service
  whose OAuth app the operator has registered in `oauth_catalog`.

  The model never sees the catalog row's client_id / client_secret.
  It calls `authorize_service(target: <slug | host | URL>)`; the
  runtime matches the target against catalog entries and:

    * If the user already has a fresh OAuth token at
      `oauth:<host_match>` → return `{status: "authorized"}` so the
      next chain can use it via `lookup_creds` + `run_script` + curl.
    * If no token (or expired beyond refresh) → fire the OAuth
      flow with `flow_kind = "oauth_service"`, return
      `{status: "needs_auth", auth_url}`. The chain ends; the
      `/oauth/callback` handler stores the token at `oauth:<host_match>`
      and dispatches `auto_resume_assistant`.
    * If the target doesn't match any catalog entry → return a
      structured `{:error, ...}` telling the model to either ask
      the admin to add the service or fall back to alternatives
      (browser_task, honest decline).

  This is the chat-driven counterpart to `connect_mcp`. Both end at
  the same `/oauth/callback` URL; the `flow_kind` column on the
  pending state distinguishes downstream handling.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Auth.{Credentials, OAuth2}
  alias DmhAi.OAuth.Catalog

  @impl true
  def name, do: "authorize_service"

  @impl true
  def description do
    """
    Authorize the user against an OAuth-protected REST service that the operator has wired into the catalog. Use this when you've discovered (via training, fetch_wiki, web_search, or a probe response) that a URL needs OAuth before you can call it.

    `target` may be a catalog slug (preferred), a host (`api.example.com`), or a full URL — the runtime matches by host suffix.

    Returns:
    - `{status: "authorized"}` — the user already has a fresh token; immediately call `lookup_creds(target: "oauth:<host>")` and proceed with `run_script` + curl.
    - `{status: "needs_auth", auth_url}` — first-time auth. Relay the auth_url as a clickable link; chain ends; the OAuth callback auto-resumes the chain after the user authorizes.
    - `{:error, reason}` — host isn't in the catalog (admin hasn't wired it), or another setup issue. Tell the user honestly and offer alternatives.
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
            description: "Slug (e.g. \"google\"), host (\"api.github.com\"), or URL of the service to authorize. The runtime matches against the catalog by host suffix."
          }
        },
        required: ["target"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id        = Map.get(ctx, :user_id)
    session_id     = Map.get(ctx, :session_id)
    anchor_n       = Map.get(ctx, :anchor_task_num)
    target_in      = Map.get(args, "target")

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, "authorize_service called without user_id in context"}

      not is_binary(session_id) or session_id == "" ->
        {:error, "authorize_service called without session_id in context"}

      not is_binary(target_in) or target_in == "" ->
        {:error, "authorize_service requires a non-empty `target` (slug, host, or URL)"}

      true ->
        case lookup_catalog(target_in) do
          nil ->
            {:error,
             "No entry in the curated OAuth catalog matches `#{target_in}`. Either the host isn't registered in this deployment yet (ask admin to add it), or this service doesn't use OAuth at all. Don't retry the same target — tell the user truthfully and offer alternatives (browser_task once available, web_search for public info, or honest decline)."}

          %{} = entry ->
            already_authorized_or_init(user_id, session_id, anchor_n, entry)
        end
    end
  end

  # ── catalog lookup ───────────────────────────────────────────────────────

  defp lookup_catalog(target) do
    # Try slug first (exact); fall through to host/URL match.
    Catalog.get_by_slug(target) || Catalog.get_by_host(target)
  end

  # ── already-authorized shortcut ──────────────────────────────────────────

  defp already_authorized_or_init(user_id, session_id, anchor_n, %{host_match: host} = entry) do
    target = "oauth:" <> host

    case OAuth2.lookup_with_refresh(user_id, target) do
      {:ok, %{kind: "oauth2_service"}} ->
        # Fresh (or just-refreshed) token. Tell the model it can
        # call lookup_creds + curl immediately.
        {:ok, %{
          status:      "authorized",
          alias:       entry.slug,
          host_match:  host,
          cred_target: target,
          message:     "User already has a valid OAuth token. Call lookup_creds(target: \"#{target}\") to read the access_token, then use it as `Authorization: Bearer <token>` in run_script + curl."
        }}

      _missing_or_unrefreshable ->
        init_oauth_flow(user_id, session_id, anchor_n, entry)
    end
  end

  # ── kick off the OAuth flow ──────────────────────────────────────────────

  defp init_oauth_flow(user_id, session_id, anchor_n, entry) do
    # We need an anchor task for parity with connect_mcp's contract —
    # OAuth flows tie to the active task so the post-callback
    # auto_resume re-enters the right anchor.
    case resolve_anchor(session_id, anchor_n) do
      {:error, msg} ->
        {:error, msg}

      {:ok, anchor_task_id} ->
        asm = %{
          authorization_endpoint: entry.authorization_endpoint,
          token_endpoint:         entry.token_endpoint,
          scopes_supported:       entry.scopes_default,
          issuer:                 entry.authorization_endpoint
        }

        redirect_uri = build_redirect_uri()

        # init_flow either returns {:ok, %{auth_url, ...}} or raises
        # (DB writes go through query!). Exceptions land in the
        # caller's outer rescue path; no error tuple to handle here.
        {:ok, %{auth_url: auth_url}} =
          OAuth2.init_flow(%{
            user_id:            user_id,
            session_id:         session_id,
            anchor_task_id:     anchor_task_id,
            alias:              entry.slug,
            canonical_resource: entry.host_match,
            server_url:         "https://" <> entry.host_match,
            asm:                asm,
            client_id:          entry.client_id,
            client_secret:      entry.client_secret,
            redirect_uri:       redirect_uri,
            scopes:             entry.scopes_default,
            flow_kind:          "oauth_service",
            extra_auth_params:  entry.extra_auth_params
          })

        {:ok, %{
          status:   "needs_auth",
          alias:    entry.slug,
          auth_url: auth_url,
          message:  "Tell the user: \"#{entry.display_name} needs your authorization. Click this link to grant access — the chat resumes automatically once you're done: #{auth_url}\". End your turn here — do not pair this with other tool calls."
        }}
    end
  end

  defp resolve_anchor(session_id, n) when is_binary(session_id) and is_integer(n) do
    case DmhAi.Agent.Tasks.resolve_num(session_id, n) do
      {:ok, task_id}       -> {:ok, task_id}
      {:error, :not_found} -> {:error, "anchor task (#{n}) not found in this session"}
    end
  end

  defp resolve_anchor(_, _),
    do: {:error, "authorize_service requires an anchor task — call create_task or pickup_task first"}

  defp build_redirect_uri do
    base = DmhAi.Agent.AgentSettings.oauth_redirect_base_url()
    String.trim_trailing(base, "/") <> "/oauth/callback"
  end

  # Dummy reference so Credentials shows up in the analyzer's reach
  # graph. We don't call it directly here — the lookup goes through
  # OAuth2.lookup_with_refresh — but the module is part of the
  # documented contract.
  _ = &Credentials.lookup/2
end
