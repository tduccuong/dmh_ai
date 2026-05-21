# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Behaviour do
  @moduledoc """
  Behaviour all tools must implement.
  """

  @doc "Unique tool name used in LLM function calls"
  @callback name() :: String.t()

  @doc "Human-readable description for the tool registry"
  @callback description() :: String.t()

  @doc "OpenAI-compatible function definition for the LLM"
  @callback definition() :: map()

  @doc "Execute the tool with parsed args and user context"
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, String.t()}

  @doc """
  Primitive 0.10 — Tools.Catalog manifest entry. Optional in v1:
  tools that don't implement this fall back to a derived manifest
  (`category: :internal`, `permission: :read_kb`, schema from
  `definition/0`). Tools that need a tighter permission gate, a
  write-class declaration, or non-default callable-from rules
  export this explicitly.

  Return shape:

      %{
        category:        :internal | :llm_synthetic,
        permission:      atom,                       # Permissions action
        permission_target: String.t() | fun,          # static target or (args, ctx) -> target
        callable_from:   [:chat | :task | :workflow],
        write_class:     :read | :write,
        idempotency:     :inferred | :required | :unsafe
      }
  """
  @callback catalog_manifest() :: map()

  @optional_callbacks catalog_manifest: 0
end
