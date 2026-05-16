# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Bootstrap do
  @moduledoc """
  Boot-time seeder for every Universal Region connector. Iterates
  `Connectors.Registry.universal_modules/0` and, for each connector
  that exposes `oauth_catalog_descriptor/0` or
  `mcp_catalog_descriptor/0`, writes the corresponding row via
  `OAuthCatalogSeed.upsert!/1` / `MCPCatalogSeed.upsert!/1`.

  Idempotent — calling on every boot is safe (and recommended).
  The seeders update fields like `display_name` / `scopes_default`
  on each call so a code-side change ripples to the DB without an
  operator running a manual migration.

  Operators can override any field via the admin catalog UI;
  re-seeding on the next boot will WIN — the descriptor is the
  source of truth. Operator overrides survive only between seeder
  calls. If an operator needs a permanent override, the right path
  is to change the connector module's descriptor function (a code
  change), not edit the DB.
  """

  alias DmhAi.Connectors.{MCPCatalogSeed, OAuthCatalogSeed, Registry}
  alias DmhAi.Connectors.Mock.VendorMCPServer
  alias DmhAi.Connectors.MCPServer
  require Logger

  @doc """
  Seed every Universal Region connector. Called once from
  `Application.start/2` after the supervision tree is up. Returns
  the count of `{oauth_seeded, mcp_seeded}`.
  """
  @spec seed_all() :: {non_neg_integer(), non_neg_integer()}
  def seed_all do
    {oauth_count, mcp_count} =
      Registry.universal_modules()
      |> Enum.reduce({0, 0}, fn mod, {oc, mc} ->
        oc2 = if function_exported?(mod, :oauth_catalog_descriptor, 0) do
          try do
            OAuthCatalogSeed.upsert!(mod.oauth_catalog_descriptor())
            oc + 1
          rescue
            e ->
              Logger.error(
                "[Connectors.Bootstrap] oauth seed failed for #{inspect(mod)}: #{Exception.message(e)}"
              )
              oc
          end
        else
          oc
        end

        mc2 = if function_exported?(mod, :mcp_catalog_descriptor, 0) do
          try do
            MCPCatalogSeed.upsert!(mod.mcp_catalog_descriptor())
            mc + 1
          rescue
            e ->
              Logger.error(
                "[Connectors.Bootstrap] mcp seed failed for #{inspect(mod)}: #{Exception.message(e)}"
              )
              mc
          end
        else
          mc
        end

        {oc2, mc2}
      end)

    Logger.info(
      "[Connectors.Bootstrap] seeded #{oauth_count} oauth_catalog row(s), " <>
        "#{mcp_count} mcp_catalog row(s)"
    )

    {oauth_count, mcp_count}
  end

  @doc """
  Start a `Mock.VendorMCPServer` instance for every connector that
  exposes a `mock_descriptor/0`. Gated by the
  `:auto_start_vendor_mocks` config flag — defaults to `false` so
  production installs never start mocks at boot. Tests don't auto-
  start either; each test calls `T.start_mock_vendor/2` directly
  to own its random-port instance.

  When the flag is on, the mock's port is read from the
  descriptor's `port_env` env var with a `default_port` fallback.
  Returns the count of mocks started.
  """
  @spec start_vendor_mocks_if_enabled() :: non_neg_integer()
  def start_vendor_mocks_if_enabled do
    if Application.get_env(:dmh_ai, :auto_start_vendor_mocks, false) do
      Registry.universal_modules()
      |> Enum.reduce(0, fn mod, n ->
        if function_exported?(mod, :mock_descriptor, 0) do
          d = mod.mock_descriptor()
          port =
            case System.get_env(d.port_env) do
              s when is_binary(s) and s != "" -> String.to_integer(s)
              _ -> d.default_port
            end

          case VendorMCPServer.start_link(
                 instance: d.instance,
                 port:     port,
                 fixtures: d.fixtures
               ) do
            {:ok, _pid} ->
              Logger.info(
                "[Connectors.Bootstrap] mock vendor MCP up: #{mod} on 127.0.0.1:#{port}"
              )
              n + 1

            {:error, reason} ->
              Logger.error(
                "[Connectors.Bootstrap] mock vendor MCP failed for #{mod}: #{inspect(reason)}"
              )
              n
          end
        else
          n
        end
      end)
    else
      0
    end
  end

  @doc """
  Start the in-process `MCPServer` on the configured port and
  mount every connector that exposes `mcp_handler_module/0`. One
  shared Plug app, one port; connectors self-route by URL path
  (`/<slug>`). Each connector's handler module owns its slug →
  functions map; the server reads from the registry on every
  request, so adding a connector requires zero code in this file.

  Always-on: the server boots regardless of whether any connector
  has a handler today. Vendor-hosted (Case B) connectors simply
  don't appear in the registry — their admins paste the vendor's
  hosted URL into the External Connectors page instead of relying
  on this server. Port is configurable via `:real_mcp_port`
  (default 8087, env `DMH_AI_REAL_MCP_PORT`).
  """
  @spec start_real_mcp_server() :: :ok | :not_started
  def start_real_mcp_server do
    port = Application.get_env(:dmh_ai, :real_mcp_port, 8087)

    handler_map =
      Registry.universal_modules()
      |> Enum.flat_map(fn mod ->
        if function_exported?(mod, :mcp_handler_module, 0) do
          handler_mod = mod.mcp_handler_module()
          if function_exported?(handler_mod, :handler, 0),
            do: [handler_mod.handler()],
            else: []
        else
          []
        end
      end)
      |> Enum.into(%{}, fn h -> {h.slug, h} end)

    DmhAi.Connectors.MCPServer.Registry.install(handler_map)

    case MCPServer.start_link(port: port) do
      {:ok, _pid} ->
        Logger.info(
          "[Connectors.Bootstrap] in-process MCPServer up: 127.0.0.1:#{port}, slugs=#{inspect(Map.keys(handler_map))}"
        )
        :ok

      {:error, reason} ->
        Logger.error("[Connectors.Bootstrap] in-process MCPServer failed: #{inspect(reason)}")
        :not_started
    end
  end
end
