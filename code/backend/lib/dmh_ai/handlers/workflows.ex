# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Workflows do
  @moduledoc """
  Read-only HTTP surface for the workflow viewer modal:

      GET /workflows/:slug/:version    → returns the version's IR JSON
      GET /workflows                   → lists workflows for the user's org

  The modal renderer fetches a specific version's IR; the list
  endpoint backs the (future) "my workflows" panel.

  Org-scoping: a user can only read workflows in their own org.
  Authentication is required (every endpoint goes through the
  existing `AuthPlug`); no role restriction (every member can read
  every workflow in their org — workflows ARE org-shared knowledge).
  Arming / saving / editing live elsewhere and gate on the
  appropriate roles.
  """

  alias DmhAi.{Workflows, Constants}
  alias DmhAi.Handlers.Proxy
  require Logger

  @doc """
  GET /workflows/:slug/:version
  Returns the IR for a specific version, plus the workflow header.
  """
  def show(conn, user, slug, version_str) do
    case Integer.parse(version_str) do
      {version, ""} when version >= 0 ->
        do_show(conn, user, slug, version)

      _ ->
        Proxy.json(conn, 400, %{error: "invalid_version", hint: "version must be a non-negative integer"})
    end
  end

  defp do_show(conn, user, slug, version) do
    org_id = Map.get(user, :org_id) || Constants.default_org_id()

    case Workflows.get_workflow(org_id, slug) do
      nil ->
        Proxy.json(conn, 404, %{error: "workflow_not_found", slug: slug})

      workflow ->
        case Workflows.get_version(org_id, slug, version) do
          nil ->
            Proxy.json(conn, 404, %{
              error:           "version_not_found",
              slug:            slug,
              requested:       version,
              current_version: workflow.current_version
            })

          v ->
            Proxy.json(conn, 200, %{
              workflow: %{
                id:              workflow.id,
                display_name:    workflow.display_name,
                current_version: workflow.current_version,
                active_version:  workflow.active_version,
                created_at:      workflow.created_at,
                updated_at:      workflow.updated_at
              },
              version: %{
                version:              v.version,
                ir:                   v.ir,
                change_note:          v.change_note,
                compiled_at:          v.compiled_at,
                compiled_in_session:  v.compiled_in_session,
                open_questions_count: v.open_questions_count
              }
            })
        end
    end
  end

  @doc "GET /workflows — list workflows in the user's org."
  def list(conn, user) do
    org_id = Map.get(user, :org_id) || Constants.default_org_id()
    workflows = Workflows.list_workflows(org_id)
    Proxy.json(conn, 200, %{workflows: workflows})
  end
end
