# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ReadWorkflow do
  @moduledoc """
  Fetch a saved workflow's current_version IR + metadata. Used for
  edit-mode: when the user says *"edit &<slug> at node N to …"*, the
  model calls this tool to load the existing IR before producing the
  new IR via `upsert_workflow`.

  Always reads `current_version`; older versions are historical and
  not editable as a base (per layer-W.md §Latest-version-only
  runnability).

  Returns `{ir, description, display_name, slug, current_version,
  created_by}`. Org-scoped via `ctx.org_id`.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.{Workflows, Constants}
  require Logger

  @impl true
  def name, do: "read_workflow"

  @impl true
  def description do
    "Read a saved workflow's current IR + metadata. " <>
      "Required arg: name (slug). Use this when the user wants to " <>
      "edit / inspect / modify an existing workflow referenced by " <>
      "`&<slug>` — load the IR with this tool, then call " <>
      "`upsert_workflow` with the modified IR."
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
            description: "The workflow's slug (its stable id, also the literal in `&<slug>` references)."
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
        {:error, "read_workflow: `name` required (string)"}

      true ->
        case Workflows.get_workflow(org_id, name_arg) do
          nil ->
            {:error, "read_workflow: no workflow named `#{name_arg}` in this org"}

          wf ->
            case Workflows.get_version(org_id, name_arg, wf.current_version) do
              nil ->
                {:error,
                 "read_workflow: workflow `#{name_arg}` has no readable version " <>
                   "(current_version=#{wf.current_version} pointer is stale)"}

              ver ->
                Logger.info("[ReadWorkflow] slug=#{name_arg} v#{wf.current_version}")

                {:ok, %{
                  "name"            => wf.id,
                  "display_name"    => wf.display_name,
                  "description"     => ver.description,
                  "current_version" => wf.current_version,
                  "created_by"      => wf.created_by,
                  "ir"              => ver.ir,
                  "url"             => "/workflows/#{URI.encode(wf.id)}/#{wf.current_version}"
                }}
            end
        end
    end
  end
end
