# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.DisarmWorkflow do
  @moduledoc """
  Companion to `arm_workflow`. Sets `workflows.active_version` to
  NULL — new trigger events are silently dropped. In-flight tasks
  pinned to a prior version finish on their pinned version; nothing
  new starts until the user explicitly re-arms.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.{Workflows, Constants}
  require Logger

  @impl true
  def name, do: "disarm_workflow"

  @impl true
  def catalog_manifest, do: %{write_class: :write}

  @impl true
  def description do
    "Deactivate a workflow — stops its trigger from firing. In-flight tasks finish; no new ones start until re-armed."
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
            description: "The workflow's slug."
          }
        },
        required: ["name"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    org_id = Map.get(ctx, :org_id) || Constants.default_org_id()
    name_arg = args["name"]

    cond do
      not is_binary(name_arg) or name_arg == "" ->
        {:error, "disarm_workflow: `name` required (string)"}

      true ->
        case Workflows.get_workflow(org_id, name_arg) do
          nil ->
            {:error, "disarm_workflow: no workflow named `#{name_arg}` in this org"}

          _ ->
            :ok = Workflows.disarm(org_id, name_arg)
            {:ok, %{"name" => name_arg, "armed" => false}}
        end
    end
  end
end
