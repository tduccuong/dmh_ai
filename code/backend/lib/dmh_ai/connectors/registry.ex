# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Registry do
  @moduledoc """
  Boot-time registration of every Universal Region connector with
  the `DmhAi.Tools.Dispatcher`. A connector module is registered
  iff its manifest passes `DmhAi.Tools.Manifest.validate/1`; a
  failing manifest is logged as `manifest_violation` and the
  connector's functions become unreachable until the manifest is
  fixed — never silently mis-registered.

  Adding a new Universal Region connector is one entry in
  `@universal_connectors` plus the corresponding adapter module
  under `DmhAi.Connectors.<Name>`.
  """

  alias DmhAi.Tools.Dispatcher
  require Logger

  # Universal Region connectors — every org gets these by default.
  # Order is irrelevant; the dispatcher's ETS registry is keyed by
  # connector slug.
  @universal_connectors [
    DmhAi.Connectors.HubSpot,
    DmhAi.Connectors.M365,
    DmhAi.Connectors.GoogleWorkspace,
    DmhAi.Connectors.Stripe,
    DmhAi.Connectors.Calendly,
    DmhAi.Connectors.Shopify,
    DmhAi.Connectors.Salesforce,
    DmhAi.Connectors.Slack,
    DmhAi.Connectors.Zoom,
    DmhAi.Connectors.Asana,
    DmhAi.Connectors.Notion,
    DmhAi.Connectors.Klaviyo,
    DmhAi.Connectors.Brevo,
    DmhAi.Connectors.Atlassian,
    DmhAi.Connectors.DocuSign
  ]

  @doc """
  Register every Universal Region connector. Idempotent — re-running
  re-validates manifests (useful for live-reload during dev) without
  duplicating ETS rows (the underlying `:ets.insert/2` overwrites).

  Returns the list of `{module, :ok | {:error, reason}}` outcomes for
  observability; callers (Application.start) typically ignore the
  return and just log any failure.
  """
  @spec register_universal() :: [{module(), :ok | {:error, term()}}]
  def register_universal do
    Dispatcher.init()

    Enum.map(@universal_connectors, fn mod ->
      case Dispatcher.register(mod) do
        :ok ->
          {mod, :ok}

        {:error, reason} = err ->
          Logger.error("[Connectors.Registry] failed to register #{inspect(mod)}: #{inspect(reason)}")
          {mod, err}
      end
    end)
  end

  @doc "List of all Universal Region connector modules (compile-time)."
  @spec universal_modules() :: [module()]
  def universal_modules, do: @universal_connectors

  @doc """
  Resolve a slug back to its connector module. `nil` when the slug
  isn't a Universal Region connector. Used by the `connect_mcp`
  dispatcher to decide between the in-process attach path and the
  vendor-hosted discover path.
  """
  @spec module_for_slug(String.t()) :: module() | nil
  def module_for_slug(slug) when is_binary(slug) do
    Enum.find(@universal_connectors, fn mod ->
      function_exported?(mod, :mcp_slug, 0) and mod.mcp_slug() == slug
    end)
  end

  @doc """
  True when the slug's connector module hosts its MCP server
  in-process (it exports `mcp_handler_module/0`). False for
  vendor-hosted Case-B connectors and for unknown slugs.
  """
  @spec in_process?(String.t()) :: boolean()
  def in_process?(slug) when is_binary(slug) do
    case module_for_slug(slug) do
      nil -> false
      mod -> function_exported?(mod, :mcp_handler_module, 0)
    end
  end
end
