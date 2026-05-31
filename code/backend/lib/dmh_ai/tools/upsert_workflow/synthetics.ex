# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.Synthetics do
  @moduledoc """
  Synthetic function names the workflow compiler may emit even
  though they aren't connector-backed. The validator passes them
  through every connector-shaped check (existence, required args,
  provenance, scopes, permissions); the runtime resolves them at
  execution time (`llm.compose`, `llm.summarise`,
  `builtin.coalesce`, `workflow.invoke`).

  Single source of truth for sibling modules in the validator.
  """

  @synthetic_functions ~w(llm.compose llm.summarise builtin.coalesce workflow.invoke)

  @doc """
  List of synthetic function names. Used by sibling validators that
  must exempt synthetic primitives from a check (manifest lookup,
  required args, OAuth scopes, provenance, permissions).
  """
  @spec list() :: [String.t()]
  def list, do: @synthetic_functions
end
