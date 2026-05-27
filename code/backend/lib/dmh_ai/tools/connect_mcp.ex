# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ConnectMcp do
  @moduledoc """
  Single user-facing tool for attaching an MCP server to the current
  session. The only argument is `slug` — a row in the admin's connector
  catalog. Two code paths under one tool, both dispatched off the slug:

    * **In-process** — slug whose connector module exports
      `mcp_handler_module/0`. DMH-AI hosts the MCP server itself
      (`Connectors.MCPServer`); authorization was pre-arranged via
      the External Connectors admin page + the user's My Services
      Connect click. Just attach. `InProcess.attach/3`.

    * **Vendor-hosted** — every other catalog slug. DMH-AI doesn't
      host this server; we resolve the catalog row to its
      `mcp_url` + `auth_kind`, then probe / discover OAuth or
      API-key metadata and run the handshake. `Vendor.connect/1`.

  Token freshness is **not** checked here. The dispatcher answers
  "did the user authorize this connector?" — a state question. The
  call-time path (`MCPAdapter.Caller`) refreshes expired bearers
  transparently via `OAuthRefresh.refresh!/1` before forwarding.
  This keeps "is the cred fresh?" out of the attach path entirely.

  Authorization is per-user (persists across sessions); the
  resulting tool catalog is per-session (visible while the
  session is active).
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Tools.ConnectMcp.{InProcess, Vendor}
  alias DmhAi.Connectors.Registry, as: ConnectorRegistry

  @impl true
  def name, do: "connect_mcp"

  @impl true
  def description do
    """
    Attach an MCP server (JSON-RPC `initialize`/`tools/list`/`tools/call`) to the current session. Pass a `slug` from the admin-curated catalog (visible in `<authorized_services>` + the org's `<authorized_services_catalog>` block).

    The runtime detects auth automatically by probing the server — you do NOT pick an auth method. The probe outcome routes the flow:
    - server is open → connected immediately.
    - server speaks OAuth 2.1 (Bearer challenge) → automatic OAuth flow with auth_url returned to the user.
    - server uses a static API key (non-Bearer challenge) → single-field form prompts the user for the key.

    Returns: `{status: "connected", alias, tools}` | `{status: "needs_auth", alias, auth_url}` | `{status: "needs_setup", alias, form}` | `{:error, reason}`. The first three are chain-terminating.

    `connect_mcp(slug: "<slug>")` attaches an admin-curated MCP server. `slug` is the ONLY argument and is REQUIRED — it identifies a row in the admin's connector catalog. After a successful attach, the connector's typed functions appear in your tools catalog as `<slug>.<function_name>`.

    Where slugs come from: read the `<authorized_services>` block — every MCP row there names a slug + a one-line scope. When the user's request falls within a slug's scope, call `connect_mcp(slug: "<slug>")` directly. The slug is a literal string copied verbatim from that block; never invent one.

    When to call it: only before YOU are about to invoke a `<slug>.<function>` tool from the connector's catalog. `connect_mcp` is what brings those tools INTO your catalog for the current chain. Workflow-meta tools (`invoke_workflow`, `read_workflow`, `arm_workflow`, `upsert_workflow`) do NOT need it — invoking a saved workflow runs through the autonomous runtime which establishes its own per-step credentials. Calling `connect_mcp` before `invoke_workflow` is wasted work.

    No URL form: this tool does NOT accept a `url` argument. The admin owns the catalog; users authorize per-slug via the My Services page. If the user names a service that isn't in `<authorized_services>` and isn't in `<pending_services>`, the deployment has no connector for it — say so honestly and offer alternatives (`web_search`, `web_fetch`, an OAuth-protected REST API via `authorize_service` if one is wired).

    `connect_mcp` returns one of:
    - `{status: "connected", tools}` → tools are live this chain as `<slug>.<tool_name>`.
    - `{status: "needs_auth", auth_url}` → relay `auth_url` as a clickable link, end chain. OAuth callback auto-resumes.
    - `{status: "needs_setup", form}` → relay the inline form (single-field API-key prompt).
    - `{:error, reason}` — auto-discovery failed or the slug isn't enabled. Tell the user honestly what happened (the reason explains it); don't retry the same slug.

    Don't pair `connect_mcp` with other tool calls — every non-`connected` shape is chain-terminating.

    `[needs_auth]` next to a slug in the `## Your authorized services` block — stale MCP creds. Tools are NOT in your catalog. Call `connect_mcp(slug: "<slug>")` to redo OAuth. Don't try to invoke `<slug>.<tool>` for a `[needs_auth]` row.

    Tools stay attached for the lifetime of the session. Re-attach is fast if needed.
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
          slug: %{
            type: "string",
            description: "Slug of an admin-curated catalog entry (must be enabled). Resolves to the row's mcp_url; the auth flow defaults from the catalog's auth_kind."
          },
          alias: %{
            type: "string",
            description: "Optional friendly label for this connection. Defaults to the slug."
          }
        },
        required: ["slug"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id    = Map.get(ctx, :user_id)
    session_id = Map.get(ctx, :session_id)
    slug       = Map.get(args, "slug")
    alias_in   = Map.get(args, "alias")

    with :ok            <- require_ctx(user_id, session_id),
         {:ok, route}   <- classify_route(slug) do
      dispatch(route, user_id, session_id, alias_in)
    end
  end

  # ── routing ────────────────────────────────────────────────────────────

  # `route` is one of:
  #   {:in_process, slug}
  #   {:vendor_slug, slug, url, auth_kind}
  defp classify_route(slug) when is_binary(slug) and slug != "" do
    if ConnectorRegistry.in_process?(slug) do
      {:ok, {:in_process, slug}}
    else
      case DmhAi.MCP.Catalog.get_by_slug(slug) do
        nil ->
          {:error, "unknown catalog slug: #{inspect(slug)}"}

        %{enabled: false} ->
          {:error, "catalog entry `#{slug}` is disabled — admin must Enable it first"}

        %{mcp_url: url, auth_kind: kind} ->
          {:ok, {:vendor_slug, slug, url, kind}}
      end
    end
  end

  defp classify_route(_),
    do: {:error, "connect_mcp requires a non-empty `slug` from the admin's connector catalog"}

  defp dispatch({:in_process, slug}, user_id, session_id, _alias_in) do
    InProcess.attach(user_id, session_id, slug)
  end

  defp dispatch({:vendor_slug, slug, url, auth_kind}, user_id, session_id, alias_in) do
    Vendor.connect(%{
      user_id:           user_id,
      session_id:        session_id,
      url:               url,
      alias_:            alias_in || slug,
      catalog_auth_kind: auth_kind
    })
  end

  # ── helpers (dispatcher-local; not shared with the two paths) ─────────

  defp require_ctx(nil, _), do: {:error, "connect_mcp called without user_id in context"}
  defp require_ctx(_, nil), do: {:error, "connect_mcp called without session_id in context"}
  defp require_ctx(_, _),    do: :ok
end
