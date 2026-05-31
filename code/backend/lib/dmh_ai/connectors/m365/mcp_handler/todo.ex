# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Todo do
  @moduledoc """
  Microsoft To Do surface — `todo.list`, `todo.create`,
  `todo.complete`.

  Microsoft To Do groups tasks into lists; every account has a
  default "Tasks" list created automatically. We resolve it by
  name ("Tasks") via GET /me/todo/lists?$filter=displayName eq 'Tasks'
  on each call. Caching the list-id would shave one round-trip but
  adds a stale-cache invalidation story not worth it yet.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers

  @graph_base Helpers.graph_base()

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "todo.list" => %FunctionSpec{
        handler: &todo_list/2,
        doc:     "List tasks on the user's default Microsoft To Do list."
      },
      "todo.create" => %FunctionSpec{
        handler: &todo_create/2,
        doc:     "Add a task to the user's default Microsoft To Do list."
      },
      "todo.complete" => %FunctionSpec{
        handler: &todo_complete/2,
        doc:     "Mark a Microsoft To Do task as completed."
      }
    }
  end

  # ─── todo.list — over the default list ────────────────────────────────

  defp todo_list(args, ctx) do
    with {:ok, list_id} <- resolve_default_todo_list(ctx) do
      opts = [
        url:     "#{@graph_base}/todo/lists/#{list_id}/tasks",
        params:  [{"$top", Map.get(args, "limit", 25)}, {"$select", "id,title,body,dueDateTime,status"}]
      ]

      case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
        {:ok, 200, %{"value" => tasks}} when is_list(tasks) ->
          {:ok, %{"tasks" => Enum.map(tasks, &normalise_todo_task/1)}}

        {:ok, _status, _body} ->
          {:error, :upstream_other}

        {:error, _} = err ->
          err
      end
    end
  end

  # ─── todo.create — append to the default list ─────────────────────────

  defp todo_create(args, ctx) do
    with {:ok, list_id} <- resolve_default_todo_list(ctx) do
      body =
        %{"title" => args["title"]}
        |> Helpers.maybe_put_kv("body", build_todo_body(Map.get(args, "body")))
        |> Helpers.maybe_put_kv("dueDateTime", build_todo_due(Map.get(args, "due")))

      opts = [url: "#{@graph_base}/todo/lists/#{list_id}/tasks", json: body]

      case RestBridge.raw_request(:post, Helpers.with_bearer(opts, ctx)) do
        {:ok, status, resp} when status in 200..299 ->
          {:ok, %{"task_id" => resp["id"], "title" => resp["title"]}}

        {:ok, _status, _body} ->
          {:error, :upstream_other}

        {:error, _} = err ->
          err
      end
    end
  end

  defp resolve_default_todo_list(ctx) do
    opts = [
      url:    "#{@graph_base}/todo/lists",
      params: [{"$filter", "displayName eq 'Tasks'"}, {"$top", 1}]
    ]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => [%{"id" => id} | _]}} -> {:ok, id}
      {:ok, 200, %{"value" => []}} ->
        # Locale variants — fall back to the first list returned
        # without a filter. Better than failing the call.
        opts_any = [url: "#{@graph_base}/todo/lists", params: [{"$top", 1}]]

        case RestBridge.raw_request(:get, Helpers.with_bearer(opts_any, ctx)) do
          {:ok, 200, %{"value" => [%{"id" => id} | _]}} -> {:ok, id}
          _ -> {:error, :not_found}
        end

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_todo_task(%{} = item) do
    %{
      "id"     => item["id"],
      "title"  => item["title"],
      "notes"  => get_in(item, ["body", "content"]),
      "due"    => get_in(item, ["dueDateTime", "dateTime"]),
      "status" => item["status"]
    }
  end

  defp build_todo_body(nil), do: nil
  defp build_todo_body(""),  do: nil
  defp build_todo_body(text), do: %{"content" => text, "contentType" => "text"}

  defp build_todo_due(nil), do: nil
  defp build_todo_due(""),  do: nil
  defp build_todo_due(iso), do: %{"dateTime" => iso, "timeZone" => "UTC"}

  # ─── todo.complete — PATCH /me/todo/lists/{list}/tasks/{task} ─────────
  # vendor: PATCH /v1.0/me/todo/lists/{list_id}/tasks/{task_id}
  #         body: {"status":"completed"}
  # docs:   https://learn.microsoft.com/graph/api/todotask-update
  # Graph sets `completedDateTime` itself when status flips.

  defp todo_complete(args, ctx) do
    list_id = Helpers.safe_path_id(args["list_id"])
    task_id = Helpers.safe_path_id(args["task_id"])

    url  = "#{@graph_base}/todo/lists/#{list_id}/tasks/#{task_id}"
    body = %{"status" => "completed"}

    case RestBridge.raw_request(:patch, Helpers.with_bearer([url: url, json: body], ctx)) do
      {:ok, status, resp} when status in 200..299 and is_map(resp) ->
        {:ok, %{"task_id" => to_string(resp["id"] || task_id)}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end
end
