# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.InvokeWorkflow do
  @moduledoc """
  Manually invoke a workflow with caller-supplied inputs. Opens a
  task pinned to the workflow's currently-armed version (or a
  caller-specified version), populating the trigger.inputs from
  the args.

  Distinct from `arm_workflow` — arming registers a trigger
  (schedule / poll / webhook) that fires the workflow autonomously.
  This tool fires a single one-off run with caller-supplied inputs,
  bypassing the trigger.

  Use cases:
  - User says *"run customer_onboarding_from_deal for deal-12345"* in chat.
  - One workflow invokes another (`workflow.invoke` as a synthetic
    step in an IR).

  v1 scope: creates the task row; the actual workflow executor that
  walks the IR step-by-step lives in a follow-up. v1 returns the
  task_id + the IR snapshot so the caller can render progress.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.{Workflows, Constants}
  alias DmhAi.Agent.Tasks
  require Logger

  @impl true
  def name, do: "invoke_workflow"

  @impl true
  def description do
    "Run a saved workflow once with supplied inputs. " <>
      "Args: name (slug), inputs (map matching the trigger's inputs), " <>
      "optional version (defaults to active_version)."
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
          },
          inputs: %{
            type:        "object",
            description: "Values for the workflow's trigger inputs, e.g. {deal: {id: '12345', contact_email: 'x@y.com'}}."
          },
          version: %{
            type:        "integer",
            description: "Optional. Default = workflows.active_version (must be armed). Pass to run a specific historical version."
          }
        },
        required: ["name", "inputs"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    org_id     = Map.get(ctx, :org_id) || Constants.default_org_id()
    user_id    = Map.get(ctx, :user_id)
    session_id = Map.get(ctx, :session_id)

    name_arg = args["name"]
    inputs   = args["inputs"]
    version  = args["version"]

    with :ok            <- require_string(name_arg, "name"),
         :ok            <- require_map(inputs, "inputs"),
         :ok            <- require_string(user_id, "ctx.user_id"),
         :ok            <- require_string(session_id, "ctx.session_id"),
         {:ok, wf}      <- fetch_workflow(org_id, name_arg),
         {:ok, version} <- resolve_version(wf, version),
         {:ok, _v}      <- fetch_version(org_id, name_arg, version) do

      task_spec =
        "Run workflow `#{name_arg}` v#{version} with inputs: #{Jason.encode!(inputs)}"

      task_id = Tasks.insert(
        user_id:    user_id,
        session_id: session_id,
        task_type:   "one_off",
        intvl_sec:  0,
        task_title:  "Run #{wf.display_name} v#{version}",
        task_spec:   task_spec,
        attachments: [],
        task_status: "pending",
        language:   "en"
      )

      Logger.info("[InvokeWorkflow] task=#{task_id} workflow=#{name_arg} v#{version} session=#{session_id}")

      {:ok, %{
        "name"             => name_arg,
        "display_name"     => wf.display_name,
        "version"          => version,
        "task_id"          => task_id,
        "url"              => "/workflows/#{URI.encode(name_arg)}/#{version}",
        "executor_status"  => "queued_v1_stub",
        "note"             => "v1: task row created; the workflow executor that walks the IR ships in chunk 6 alongside the poller. Until then the task is a placeholder."
      }}
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  defp require_string(v, _label) when is_binary(v) and v != "", do: :ok
  defp require_string(_, label),
    do: {:error, "invoke_workflow: missing #{label}"}

  defp require_map(v, _label) when is_map(v), do: :ok
  defp require_map(_, label),
    do: {:error, "invoke_workflow: `#{label}` must be a JSON object"}

  defp fetch_workflow(org_id, name) do
    case Workflows.get_workflow(org_id, name) do
      nil -> {:error, "invoke_workflow: no workflow `#{name}` in this org"}
      wf  -> {:ok, wf}
    end
  end

  defp resolve_version(_wf, v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp resolve_version(%{active_version: av}, _) when is_integer(av), do: {:ok, av}
  defp resolve_version(_, _),
    do: {:error, "invoke_workflow: workflow is not armed and no version arg supplied — pass version: N or call arm_workflow first"}

  defp fetch_version(org_id, name, v) do
    case Workflows.get_version(org_id, name, v) do
      nil -> {:error, "invoke_workflow: workflow `#{name}` has no version #{v}"}
      ver -> {:ok, ver}
    end
  end
end
