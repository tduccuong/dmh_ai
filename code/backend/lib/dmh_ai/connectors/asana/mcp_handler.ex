# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Asana.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Asana connector consumed by the generic
  `Connectors.MCPServer`. Each function is a 1:1 mapping to an Asana
  REST endpoint at `https://app.asana.com/api/1.0/*`:

    workspace.find — GET    /workspaces
    team.find      — GET    /organizations/{workspace_id}/teams
    project.find   — GET    /projects
    project.create — POST   /projects
    section.find   — GET    /projects/{project_id}/sections
    section.create — POST   /projects/{project_id}/sections
    task.find      — GET    /projects/{project_id}/tasks
    task.create    — POST   /tasks
    task.update    — PUT    /tasks/{task_id}
    task.assign    — PUT    /tasks/{task_id}
    task.complete  — PUT    /tasks/{task_id}
    task.delete    — DELETE /tasks/{task_id}
    subtask.find   — GET    /tasks/{parent_task_id}/subtasks
    subtask.create — POST   /tasks/{parent_task_id}/subtasks
    story.create   — POST   /tasks/{task_id}/stories
    user.find      — GET    /users/{user_id_or_me}

  Fixed host (`https://app.asana.com/api/1.0`), no per-instance
  templating. Standard `Authorization: Bearer <token>` auth, which
  `RestBridge` injects from `ctx.bearer_token`.

  ## The `"data"` envelope

  Every Asana request body and response is wrapped in a top-level
  `"data"` key. So each `request` builder nests its fields under
  `%{"data" => %{...}}`, and each `response` parser unwraps
  `body["data"]` — which is a single object (`/tasks/{id}`) or a
  list (`/projects`) — before mapping to the declared canonical
  returns.

  ## Path-param ids

  Asana targets the authed user with the literal path segment `me`
  (`/users/me`). Functions acting on a specific object interpolate
  the gid into the path via a `:url` function `(args -> url)`. The
  id is whitelisted to `^[A-Za-z0-9_-]+$` before the URL is built
  (`safe_path_id/1`) — no raw interpolation of unvalidated input.
  `user.find` defaults the path segment to `me` when the optional
  `user_id` arg is absent.

  ## Error body

  Asana returns normal HTTP status codes; the `RestBridge` keys
  success off the 2xx status. On a 4xx/5xx Asana frames a JSON body
  `%{"errors" => [%{"message" => ...}, ...]}` which the bridge
  surfaces and the connector's `remap_error/1` maps to the canonical
  class (driven by HTTP status).
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec
  require Logger

  @api_base "https://app.asana.com/api/1.0"

  # Asana object gids are digit strings. Whitelist the charset before
  # interpolating into a URL path so an attacker can't inject path
  # segments or query strings via a lookup arg.
  @path_id_re ~r/^[A-Za-z0-9_-]+$/

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "asana", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "project.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/projects",
        request: &project_find_request/2,
        response: &project_find_response/2,
        doc:     "List projects (optional workspace filter)."
      },
      "project.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/projects",
        request: &project_create_request/2,
        response: &project_create_response/2,
        doc:     "Create a project in a workspace."
      },
      "task.find" => %FunctionSpec{
        method:  :get,
        url:     &task_find_url/1,
        request: &task_find_request/2,
        response: &task_find_response/2,
        doc:     "List tasks inside a project."
      },
      "task.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/tasks",
        request: &task_create_request/2,
        response: &task_create_response/2,
        doc:     "Create a task (optionally in a project)."
      },
      "task.update" => %FunctionSpec{
        method:  :put,
        url:     &task_update_url/1,
        request: &task_update_request/2,
        response: &task_update_response/2,
        doc:     "Patch task fields (name, notes, due_on, …)."
      },
      "task.complete" => %FunctionSpec{
        method:  :put,
        url:     &task_complete_url/1,
        request: &task_complete_request/2,
        response: &task_complete_response/2,
        doc:     "Mark a task complete."
      },
      "story.create" => %FunctionSpec{
        method:  :post,
        url:     &story_create_url/1,
        request: &story_create_request/2,
        response: &story_create_response/2,
        doc:     "Add a comment (story) to a task."
      },
      "user.find" => %FunctionSpec{
        method:  :get,
        url:     &user_find_url/1,
        response: &user_find_response/2,
        doc:     "Read a user (defaults to the authed user)."
      },
      "workspace.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/workspaces",
        request: &workspace_find_request/2,
        response: &workspace_find_response/2,
        doc:     "List workspaces the authed user belongs to."
      },
      "team.find" => %FunctionSpec{
        method:  :get,
        url:     &team_find_url/1,
        request: &team_find_request/2,
        response: &team_find_response/2,
        doc:     "List teams in an organisation workspace."
      },
      "section.find" => %FunctionSpec{
        method:  :get,
        url:     &section_find_url/1,
        request: &section_find_request/2,
        response: &section_find_response/2,
        doc:     "List sections inside a project."
      },
      "section.create" => %FunctionSpec{
        method:  :post,
        url:     &section_create_url/1,
        request: &section_create_request/2,
        response: &section_create_response/2,
        doc:     "Create a section in a project."
      },
      "task.assign" => %FunctionSpec{
        method:  :put,
        url:     &task_assign_url/1,
        request: &task_assign_request/2,
        response: &task_assign_response/2,
        doc:     "Assign an existing task to a user."
      },
      "task.delete" => %FunctionSpec{
        method:  :delete,
        url:     &task_delete_url/1,
        request: fn _args, _ctx -> [] end,
        response: &task_delete_response/2,
        doc:     "Delete a task."
      },
      "subtask.find" => %FunctionSpec{
        method:  :get,
        url:     &subtask_find_url/1,
        request: &subtask_find_request/2,
        response: &subtask_find_response/2,
        doc:     "List subtasks under a parent task."
      },
      "subtask.create" => %FunctionSpec{
        method:  :post,
        url:     &subtask_create_url/1,
        request: &subtask_create_request/2,
        response: &subtask_create_response/2,
        doc:     "Create a subtask under a parent task."
      }
    }
  end

  # ─── project.find — GET /projects ─────────────────────────────────────

  defp project_find_request(args, _ctx) do
    params =
      %{}
      |> maybe_put_kv("workspace", Map.get(args, "workspace_id"))
      |> maybe_put_kv("limit",     Map.get(args, "limit"))

    [params: params]
  end

  defp project_find_response(s, body) when s in 200..299 do
    {:ok, %{"projects" => unwrap_list(body)}}
  end

  # ─── project.create — POST /projects ──────────────────────────────────

  defp project_create_request(args, _ctx) do
    data =
      %{"name" => args["name"]}
      |> maybe_put_kv("workspace", Map.get(args, "workspace_id"))

    [json: %{"data" => data}]
  end

  defp project_create_response(s, body) when s in 200..299 do
    {:ok, %{"project_id" => to_string(unwrap_obj(body)["gid"])}}
  end

  # ─── task.find — GET /projects/{project_id}/tasks ─────────────────────

  defp task_find_url(args),
    do: "#{@api_base}/projects/#{safe_path_id(args["project_id"])}/tasks"

  defp task_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "limit", Map.get(args, "limit"))
    [params: params]
  end

  defp task_find_response(s, body) when s in 200..299 do
    {:ok, %{"tasks" => unwrap_list(body)}}
  end

  # ─── task.create — POST /tasks ────────────────────────────────────────

  defp task_create_request(args, _ctx) do
    data =
      %{"name" => args["name"]}
      |> maybe_put_kv("projects", wrap_project(Map.get(args, "project_id")))
      |> maybe_put_kv("notes",    Map.get(args, "notes"))
      |> maybe_put_kv("due_on",   Map.get(args, "due_on"))

    [json: %{"data" => data}]
  end

  defp task_create_response(s, body) when s in 200..299 do
    {:ok, %{"task_id" => to_string(unwrap_obj(body)["gid"])}}
  end

  # ─── task.update — PUT /tasks/{task_id} ───────────────────────────────

  defp task_update_url(args), do: "#{@api_base}/tasks/#{safe_path_id(args["task_id"])}"

  defp task_update_request(args, _ctx) do
    [json: %{"data" => args["patch"] || %{}}]
  end

  defp task_update_response(s, body) when s in 200..299 do
    {:ok, %{"task_id" => to_string(unwrap_obj(body)["gid"])}}
  end

  # ─── task.complete — PUT /tasks/{task_id} ─────────────────────────────

  defp task_complete_url(args), do: "#{@api_base}/tasks/#{safe_path_id(args["task_id"])}"

  defp task_complete_request(_args, _ctx) do
    [json: %{"data" => %{"completed" => true}}]
  end

  defp task_complete_response(s, body) when s in 200..299 do
    {:ok, %{"task_id" => to_string(unwrap_obj(body)["gid"])}}
  end

  # ─── story.create — POST /tasks/{task_id}/stories ─────────────────────

  defp story_create_url(args),
    do: "#{@api_base}/tasks/#{safe_path_id(args["task_id"])}/stories"

  defp story_create_request(args, _ctx) do
    [json: %{"data" => %{"text" => args["text"]}}]
  end

  defp story_create_response(s, body) when s in 200..299 do
    {:ok, %{"story_id" => to_string(unwrap_obj(body)["gid"])}}
  end

  # ─── user.find — GET /users/{user_id_or_me} ───────────────────────────

  # Default the path segment to `me` when the optional `user_id` arg is
  # absent; whitelist a provided id before interpolating it.
  defp user_find_url(args) do
    segment =
      case Map.get(args, "user_id") do
        v when is_binary(v) and v != "" -> safe_path_id(v)
        _ -> "me"
      end

    "#{@api_base}/users/#{segment}"
  end

  defp user_find_response(s, body) when s in 200..299 do
    {:ok, %{"user" => unwrap_obj(body)}}
  end

  # ─── workspace.find — GET /workspaces ─────────────────────────────────

  defp workspace_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "limit", Map.get(args, "limit"))
    [params: params]
  end

  defp workspace_find_response(s, body) when s in 200..299 do
    {:ok, %{"workspaces" => unwrap_list(body)}}
  end

  # ─── team.find — GET /organizations/{workspace_id}/teams ──────────────
  #
  # Asana exposes per-organisation team listings under
  # `/organizations/{workspace_id}/teams`. Workspaces that are not
  # organisations surface a vendor error; the dispatcher's
  # `remap_error/1` keyed off the HTTP status classifies that.

  defp team_find_url(args),
    do: "#{@api_base}/organizations/#{safe_path_id(args["workspace_id"])}/teams"

  defp team_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "limit", Map.get(args, "limit"))
    [params: params]
  end

  defp team_find_response(s, body) when s in 200..299 do
    {:ok, %{"teams" => unwrap_list(body)}}
  end

  # ─── section.find — GET /projects/{project_id}/sections ───────────────

  defp section_find_url(args),
    do: "#{@api_base}/projects/#{safe_path_id(args["project_id"])}/sections"

  defp section_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "limit", Map.get(args, "limit"))
    [params: params]
  end

  defp section_find_response(s, body) when s in 200..299 do
    {:ok, %{"sections" => unwrap_list(body)}}
  end

  # ─── section.create — POST /projects/{project_id}/sections ────────────

  defp section_create_url(args),
    do: "#{@api_base}/projects/#{safe_path_id(args["project_id"])}/sections"

  defp section_create_request(args, _ctx) do
    [json: %{"data" => %{"name" => args["name"]}}]
  end

  defp section_create_response(s, body) when s in 200..299 do
    {:ok, %{"section_id" => to_string(unwrap_obj(body)["gid"])}}
  end

  # ─── task.assign — PUT /tasks/{task_id} ───────────────────────────────
  #
  # Sub-op of `task.update` — explicit verb so the lookup chain can
  # pivot from a `user.find` straight to "assign this task to that
  # user" without composing a free-form patch.

  defp task_assign_url(args), do: "#{@api_base}/tasks/#{safe_path_id(args["task_id"])}"

  defp task_assign_request(args, _ctx) do
    [json: %{"data" => %{"assignee" => args["assignee_id"]}}]
  end

  defp task_assign_response(s, body) when s in 200..299 do
    {:ok, %{"task_id" => to_string(unwrap_obj(body)["gid"])}}
  end

  # ─── task.delete — DELETE /tasks/{task_id} ────────────────────────────
  #
  # Asana's DELETE returns the deleted task object inside `"data"`;
  # the parser ignores the payload and returns `%{ok: true}`. The
  # `returns: %{ok: :boolean}` manifest entry maps to that shape.

  defp task_delete_url(args), do: "#{@api_base}/tasks/#{safe_path_id(args["task_id"])}"

  defp task_delete_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── subtask.find — GET /tasks/{parent_task_id}/subtasks ──────────────

  defp subtask_find_url(args),
    do: "#{@api_base}/tasks/#{safe_path_id(args["parent_task_id"])}/subtasks"

  defp subtask_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "limit", Map.get(args, "limit"))
    [params: params]
  end

  defp subtask_find_response(s, body) when s in 200..299 do
    {:ok, %{"subtasks" => unwrap_list(body)}}
  end

  # ─── subtask.create — POST /tasks/{parent_task_id}/subtasks ───────────

  defp subtask_create_url(args),
    do: "#{@api_base}/tasks/#{safe_path_id(args["parent_task_id"])}/subtasks"

  defp subtask_create_request(args, _ctx) do
    data =
      %{"name" => args["name"]}
      |> maybe_put_kv("notes",    Map.get(args, "notes"))
      |> maybe_put_kv("assignee", Map.get(args, "assignee_id"))

    [json: %{"data" => data}]
  end

  defp subtask_create_response(s, body) when s in 200..299 do
    {:ok, %{"subtask_id" => to_string(unwrap_obj(body)["gid"])}}
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  # Asana wraps every response in a top-level `"data"` key. `unwrap_obj/1`
  # returns the inner object for single-resource reads / writes;
  # `unwrap_list/1` returns the inner collection for list reads. Both
  # tolerate an already-unwrapped body (defensive) and a missing key.
  defp unwrap_obj(%{"data" => obj}) when is_map(obj), do: obj
  defp unwrap_obj(body) when is_map(body), do: body
  defp unwrap_obj(_), do: %{}

  defp unwrap_list(%{"data" => list}) when is_list(list), do: list
  defp unwrap_list(_), do: []

  # `task.create` accepts an optional project gid; Asana's `projects`
  # field is a list of gids. Return nil (so `maybe_put_kv` drops it)
  # when no project was given.
  defp wrap_project(nil), do: nil
  defp wrap_project(""),  do: nil
  defp wrap_project(id),  do: [id]

  # Whitelist a path-param id to the Asana gid charset before
  # interpolating it into a URL. A value that doesn't match raises —
  # the dispatcher surfaces it as an error envelope rather than
  # building a URL with an injected segment / query string.
  defp safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid asana id: #{inspect(id)}"
    end
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
