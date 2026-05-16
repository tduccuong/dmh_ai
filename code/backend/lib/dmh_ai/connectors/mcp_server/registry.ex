# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPServer.Registry do
  @moduledoc """
  Slug → MCPServer handler map. Populated at application boot by
  `Connectors.Bootstrap.register_real_mcp_handlers/0`. The
  MCPServer Plug looks up the handler by slug taken from the
  request path (e.g. `POST /google_workspace` routes to whichever
  module registered `slug="google_workspace"`).

  Stored in `:persistent_term` so the Plug's hot path is a single
  ETS-class lookup with no GenServer round-trip.
  """

  @key :dmh_ai_mcp_server_handlers

  @typedoc """
  A registered handler: the connector slug + its function spec map.
  Handlers are decoupled from the model-facing manifest
  (`MCPAdapter` behaviour) so a connector module can grow / shrink
  its REST surface without touching the model's view.
  """
  @type handler :: %{
          required(:slug)  => String.t(),
          required(:functions) => %{required(String.t()) => DmhAi.Connectors.MCPServer.FunctionSpec.t()}
        }

  @doc "Replace the entire handler map. Boot-time only."
  @spec install(%{String.t() => handler()}) :: :ok
  def install(map) when is_map(map) do
    :persistent_term.put(@key, map)
  end

  @doc "Add or replace one handler by slug. Useful in tests."
  @spec put(handler()) :: :ok
  def put(%{slug: slug} = handler) when is_binary(slug) do
    current = :persistent_term.get(@key, %{})
    :persistent_term.put(@key, Map.put(current, slug, handler))
  end

  @doc "Look up a handler by slug. Returns `nil` if not registered."
  @spec get(String.t()) :: handler() | nil
  def get(slug) when is_binary(slug) do
    :persistent_term.get(@key, %{}) |> Map.get(slug)
  end

  @doc "Every registered slug."
  @spec slugs() :: [String.t()]
  def slugs do
    :persistent_term.get(@key, %{}) |> Map.keys() |> Enum.sort()
  end

  @doc "Reset (tests)."
  @spec reset() :: :ok
  def reset, do: :persistent_term.put(@key, %{})
end
