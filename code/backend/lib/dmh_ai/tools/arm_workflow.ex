# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ArmWorkflow do
  @moduledoc """
  Activate a saved workflow version — sets `workflows.active_version`
  to the given version. From this point the workflow's trigger
  (schedule / poll / webhook) starts firing, opening silent tasks
  pinned to this version.

  Saving a workflow is NOT arming it. Drafts must be explicitly
  armed; iterating on a workflow may save five versions during
  design, and arming any of them prematurely would be dangerous.

  Companion tool: `disarm_workflow(name)` flips `active_version` back
  to NULL. In-flight tasks finish on their pinned version; no new
  tasks start until re-armed.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.{Workflows, Constants}
  require Logger

  @impl true
  def name, do: "arm_workflow"

  @impl true
  def description do
    "Activate a saved workflow version so its trigger starts firing. " <>
      "Required args: name, version. Use `disarm_workflow` to stop it."
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          name: %{
            type:        "string",
            description: "The workflow's slug (its stable id, returned by `upsert_workflow`)."
          },
          version: %{
            type:        "integer",
            description: "The version to activate. Must be a version that has been saved (≤ current_version)."
          }
        },
        required: ["name", "version"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    org_id = Map.get(ctx, :org_id) || Constants.default_org_id()
    name_arg = args["name"]
    version  = args["version"]

    cond do
      not is_binary(name_arg) or name_arg == "" ->
        {:error, "arm_workflow: `name` required (string)"}

      not is_integer(version) or version < 0 ->
        {:error, "arm_workflow: `version` required (non-negative integer)"}

      true ->
        case Workflows.arm(org_id, name_arg, version) do
          :ok ->
            wf = Workflows.get_workflow(org_id, name_arg)
            {:ok, %{
              "name"            => name_arg,
              "armed_version"   => version,
              "current_version" => wf.current_version,
              "url"             => "/workflows/#{URI.encode(name_arg)}/#{version}"
            }}

          {:error, :workflow_not_found} ->
            {:error, "arm_workflow: no workflow named `#{name_arg}` in this org"}

          {:error, :version_not_found} ->
            {:error, "arm_workflow: workflow `#{name_arg}` has no version #{version} (only versions 0..#{(Workflows.get_workflow(org_id, name_arg) || %{current_version: -1}).current_version} exist)"}

          {:error, other} ->
            {:error, "arm_workflow: #{inspect(other)}"}
        end
    end
  end
end
