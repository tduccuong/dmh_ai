# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ConnectMcp.InProcess do
  @moduledoc """
  Attach path for connector slugs whose MCP server is hosted
  in-process by DMH-AI (`DmhAi.Connectors.MCPServer`). The
  connector module signals "I'm in-process" by exporting
  `mcp_handler_module/0`.

  Three things this attach does, all read-side / state checks:

    1. Verify the user authorized this connector — presence of an
       `authorized_services` row for `(user_id, slug)`. Missing →
       `needs_auth` envelope pointing at My Services.

    2. Verify the user's granted OAuth scopes still cover the
       admin's current `enabled_capabilities` for this slug. If
       admin added a new capability since the user last
       Connected, the granted scope set won't cover required →
       `needs_reauth` envelope with an auth_url scoped to the
       updated set, so the user can re-grant the missing scopes.

    3. Filter the tool catalog by `enabled_capabilities` (Layer 2
       of the 3-layer admin-policy enforcement). Functions in
       capabilities the admin un-ticked don't appear in the
       model's catalog — even though the user's token may still
       carry the underlying scope.

  No bearer-token freshness check at attach time; refresh-on-use
  lives in `MCPAdapter.Caller` at call boundary.
  """

  alias DmhAi.MCP.Registry, as: MCPRegistry
  alias DmhAi.Connectors.Registry, as: ConnectorRegistry
  alias DmhAi.Connectors.MCPServer
  alias DmhAi.Connectors.Capabilities
  alias DmhAi.Auth.Credentials
  require Logger

  @doc """
  Attach an in-process connector slug to the active task. Returns
  `{:ok, %{status: "connected", alias, tools}}` when authorized and
  scopes cover policy; `{:ok, %{status: "needs_reauth", auth_url, ...}}`
  when scopes are stale relative to admin's current capability set;
  `{:error, envelope}` when no authorization exists.
  """
  @spec attach(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def attach(user_id, anchor_task_id, slug)
      when is_binary(user_id) and is_binary(anchor_task_id) and is_binary(slug) do
    org_id = DmhAi.Orgs.for_user(user_id)

    with {:ok, handler} <- resolve_handler(slug),
         :ok            <- ensure_authorized(user_id, slug),
         :ok            <- ensure_scopes_cover_policy(user_id, slug, org_id) do
      # Layer 2 enforcement — render the tool catalog with the
      # admin's curated subset only. Disabled-capability functions
      # don't appear here even if the user's OAuth token has the
      # underlying scope.
      enabled_funcs = Capabilities.enabled_functions(slug, org_id)
      tools         = MCPServer.tools_list_for(handler, enabled_funcs)

      MCPRegistry.set_authorized_tools(user_id, slug, tools)
      MCPRegistry.attach(anchor_task_id, user_id, slug)
      Logger.info("[ConnectMcp.InProcess] attached slug=#{slug} user=#{user_id} task=#{anchor_task_id} tools=#{length(tools)}")
      {:ok, %{status: "connected", alias: slug, tools: tools}}
    else
      {:needs_reauth, payload} -> {:ok, payload}
      other                     -> other
    end
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp resolve_handler(slug) do
    mod = ConnectorRegistry.module_for_slug(slug)

    cond do
      is_nil(mod) ->
        {:error, "unknown in-process connector slug: #{inspect(slug)}"}

      not function_exported?(mod, :mcp_handler_module, 0) ->
        {:error, "connector `#{slug}` is not an in-process connector"}

      true ->
        handler_mod = mod.mcp_handler_module()
        {:ok, handler_mod.handler()}
    end
  end

  defp ensure_authorized(user_id, slug) do
    case MCPRegistry.find_authorized(user_id, slug) do
      %{} -> :ok
      _ ->
        {:error,
         "Connector `#{slug}` is not authorized for this user. Tell the user " <>
           "to open **My Services** → **Connect " <> humanise(slug) <>
           "** and complete the OAuth flow. After they finish, retry connect_mcp."}
    end
  end

  # Compares scopes the user has actually granted (from the MCP
  # credential's `payload.scope`) against scopes the admin's current
  # `enabled_capabilities` require. If admin ticked new capabilities
  # since the user last Connected, the granted set won't cover
  # required and we surface a `needs_reauth` envelope guiding the
  # user back to My Services.
  defp ensure_scopes_cover_policy(user_id, slug, org_id) do
    required = Capabilities.enabled_scopes(slug, org_id) |> MapSet.new()

    if MapSet.size(required) == 0 do
      :ok
    else
      granted = granted_scopes(user_id, slug) |> MapSet.new()

      if MapSet.subset?(required, granted) do
        # Self-healing: a prior failed check (or a prior buggy
        # check) may have left `authorized_services.status` stuck
        # on `needs_auth`. Now that scopes cover the policy, flip
        # it back so My Services drops the Reconnect badge. No-op
        # when the row is already `authorized`.
        MCPRegistry.mark_authorized(user_id, slug)
        :ok
      else
        missing = MapSet.difference(required, granted) |> MapSet.to_list()
        # Flip the row to `needs_auth` so the My Services FE
        # surfaces a Reconnect button alongside the model's
        # textual nudge. The two surfaces converge: whether the
        # user reads the agent's reply or notices the banner on
        # My Services, the recovery action is the same.
        MCPRegistry.mark_needs_auth(user_id, slug)
        {:needs_reauth, needs_reauth_envelope(slug, missing)}
      end
    end
  end

  # Union of scopes across every account row the user holds for this
  # slug's MCP target. A previous version hard-coded `account=""` and
  # missed connectors that populate the `account` label (e.g. Calendly,
  # whose `userinfo_endpoint` extracts the user's email) — the row
  # exists with `account="<email>"`, the empty-string lookup misses,
  # and the scope check sees an empty grant. `lookup_all/2` ignores
  # the account dimension and lets us aggregate; for the one-to-one
  # case (the common path) this is the same row, for multi-account
  # users this is the union of their grants.
  defp granted_scopes(user_id, slug) do
    case MCPRegistry.find_authorized(user_id, slug) do
      %{canonical_resource: resource} ->
        "mcp:" <> resource
        |> then(&Credentials.lookup_all(user_id, &1))
        |> Enum.flat_map(fn
          %{payload: %{"scope" => scope}} when is_binary(scope) ->
            String.split(scope, ~r/\s+/, trim: true)
          _ ->
            []
        end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp needs_reauth_envelope(slug, missing_scopes) do
    %{
      status:  "needs_reauth",
      alias:   slug,
      missing_scopes: missing_scopes,
      message:
        "Admin updated `#{slug}` capabilities. Reconnect via **My Services** → " <>
          "**Connect " <> humanise(slug) <> "** to grant the new scopes: " <>
          Enum.join(missing_scopes, ", ") <> "."
    }
  end

  defp humanise(slug) do
    slug
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
