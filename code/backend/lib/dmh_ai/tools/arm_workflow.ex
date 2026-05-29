# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ArmWorkflow do
  @moduledoc """
  Activate a saved workflow so its autonomous trigger (schedule /
  poll / webhook) starts firing. Always arms the workflow's
  `current_version`; non-latest versions are historical and not
  runnable. A subsequent `upsert_workflow` auto-bumps the armed
  snapshot in lockstep.

  Saving a workflow is NOT arming it. Drafts must be explicitly
  armed; iterating on a workflow may save five versions during
  design, and arming any of them prematurely would be dangerous.

  Companion tool: `disarm_workflow(name)` flips the armed state back
  off. In-flight tasks finish on their pinned version; no new tasks
  start until re-armed.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.{Workflows, Constants}
  require Logger

  @impl true
  def name, do: "arm_workflow"

  @impl true
  def catalog_manifest, do: %{write_class: :write}

  @impl true
  def description do
    "Activate a saved workflow so its autonomous trigger starts firing. " <>
      "Required arg: name. Always arms the latest saved version. " <>
      "Use `disarm_workflow` to stop it."
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
        {:error, "arm_workflow: `name` required (string)"}

      true ->
        case Workflows.arm(org_id, name_arg) do
          :ok ->
            wf  = Workflows.get_workflow(org_id, name_arg)
            ver = Workflows.get_version(org_id, name_arg, wf.current_version)

            base = %{
              "name"            => name_arg,
              "armed_version"   => wf.current_version,
              "current_version" => wf.current_version,
              "url"             => "/workflows/#{URI.encode(name_arg)}/#{wf.current_version}"
            }

            {:ok, maybe_add_webhook_url(base, org_id, name_arg, ver)}

          {:error, :workflow_not_found} ->
            {:error, "arm_workflow: no workflow named `#{name_arg}` in this org"}

          {:error, other} ->
            {:error, "arm_workflow: #{inspect(other)}"}
        end
    end
  end

  # For webhook-triggered workflows, include the canonical ingress URL
  # in the tool return. The model surfaces it in chat so the user can
  # paste it into the external SaaS's webhook configuration.
  defp maybe_add_webhook_url(base, org_id, _name, ver) do
    trigger_kind =
      case ver do
        %{ir: ir} ->
          ir
          |> Map.get("nodes", [])
          |> Enum.find(fn n -> n["kind"] == "trigger" end)
          |> case do
            nil -> "manual"
            t   -> Map.get(t, "trigger_kind", "manual")
          end

        _ ->
          "manual"
      end

    if trigger_kind == "webhook" do
      Map.put(base, "webhook_url",
        DmhAi.Handlers.WfWebhook.webhook_url(org_id, base["name"]))
    else
      base
    end
  end
end
