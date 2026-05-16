# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Capabilities do
  @moduledoc """
  Single source of truth for "which capabilities does the admin
  have enabled for this slug?" + the derived predicates every
  enforcement layer needs:

    * `enabled_capabilities/2` — resolves the admin's curated
      capability id set from `mcp_catalog.enabled_capabilities`,
      falling back to "all capability ids the connector exports"
      when the row's column is NULL (a fresh row the admin
      hasn't yet curated — preserves today's all-enabled
      behaviour).
    * `enabled_scopes/2` — flatten capability scopes for OAuth
      consent URL assembly (Layer 1 — MeServices.connect/2).
    * `enabled_functions/2` — flatten capability functions for
      the tool-catalog filter (Layer 2 — MCPServer.tools_list_for)
      and the dispatcher gate (Layer 3 — Dispatcher.call/3).
    * `function_enabled?/3` — fast single-function gate; what
      Dispatcher consults per call.

  All four read the same input shape: `(connector_module, org_id)`.
  The connector module supplies its full capability surface via
  `capabilities/0`; the per-org `mcp_catalog` row supplies the
  curated subset. Slugs whose connector module doesn't export
  `capabilities/0` return :all everywhere (the connector hasn't
  migrated to the capability model yet — assume full surface).
  """

  alias DmhAi.Repo
  alias DmhAi.Connectors.Registry, as: ConnectorRegistry
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Capability ids enabled for `(slug, org_id)`. Returns the list of
  ids the admin has ticked, or `:all` when the connector hasn't
  migrated to the capability model (no `capabilities/0` callback).
  """
  @spec enabled_capability_ids(String.t(), String.t()) :: [String.t()] | :all
  def enabled_capability_ids(slug, org_id) when is_binary(slug) and is_binary(org_id) do
    case ConnectorRegistry.module_for_slug(slug) do
      nil -> :all
      mod ->
        if function_exported?(mod, :capabilities, 0) do
          all_caps = mod.capabilities() |> Enum.map(& &1.id)
          row_ids  = read_enabled_capabilities(slug, org_id)
          case row_ids do
            nil    -> all_caps
            list   -> Enum.filter(list, &(&1 in all_caps))
          end
        else
          :all
        end
    end
  end

  @doc """
  Union of all OAuth scopes for the enabled capabilities. Used by
  `MeServices.connect/2` to build the consent URL — a user clicking
  Connect grants ONLY these scopes regardless of what the connector
  could in principle request.
  """
  @spec enabled_scopes(String.t(), String.t()) :: [String.t()]
  def enabled_scopes(slug, org_id) do
    with_capabilities(slug, org_id, fn caps, enabled ->
      caps
      |> filter_by_enabled(enabled)
      |> Enum.flat_map(&(&1.scopes || []))
      |> Enum.uniq()
    end)
  end

  @doc """
  Set of function names the enabled capabilities expose. Used by
  the tool-catalog filter (Layer 2) and the dispatcher gate
  (Layer 3). Returns `:all` when the connector hasn't migrated to
  capabilities (every function in the manifest is exposed).
  """
  @spec enabled_functions(String.t(), String.t()) :: MapSet.t(String.t()) | :all
  def enabled_functions(slug, org_id) do
    case ConnectorRegistry.module_for_slug(slug) do
      nil -> :all
      mod ->
        if function_exported?(mod, :capabilities, 0) do
          caps    = mod.capabilities()
          enabled = enabled_capability_ids(slug, org_id)
          caps
          |> filter_by_enabled(enabled)
          |> Enum.flat_map(&(&1.functions || []))
          |> MapSet.new()
        else
          :all
        end
    end
  end

  @doc """
  Per-call dispatcher gate. Returns true when `function_name` (e.g.
  `"gmail.search"`, NOT slug-prefixed) is exposed by an enabled
  capability for this `(slug, org_id)`, false otherwise.
  """
  @spec function_enabled?(String.t(), String.t(), String.t()) :: boolean()
  def function_enabled?(slug, function_name, org_id) do
    case enabled_functions(slug, org_id) do
      :all  -> true
      set   -> MapSet.member?(set, function_name)
    end
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp with_capabilities(slug, org_id, fun) do
    case ConnectorRegistry.module_for_slug(slug) do
      nil -> []
      mod ->
        if function_exported?(mod, :capabilities, 0) do
          fun.(mod.capabilities(), enabled_capability_ids(slug, org_id))
        else
          []
        end
    end
  end

  defp filter_by_enabled(caps, :all), do: caps

  defp filter_by_enabled(caps, enabled_ids) when is_list(enabled_ids) do
    Enum.filter(caps, fn cap -> cap.id in enabled_ids end)
  end

  defp read_enabled_capabilities(slug, org_id) do
    case query!(Repo, """
    SELECT enabled_capabilities FROM mcp_catalog
    WHERE slug=? AND org_id=? LIMIT 1
    """, [slug, org_id]).rows do
      [[nil]] -> nil
      [[""]]  -> nil
      [[json]] ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> list
          _ -> nil
        end
      _ -> nil
    end
  end
end
