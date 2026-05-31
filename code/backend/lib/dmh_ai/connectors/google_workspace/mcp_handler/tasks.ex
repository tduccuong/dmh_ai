# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Tasks do
  @moduledoc """
  Google Tasks surface — `tasks.list`, `tasks.create`.
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec

  @tasks_base "https://tasks.googleapis.com/tasks/v1"

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "tasks.list" => %FunctionSpec{
        method:  :get,
        url:     "#{@tasks_base}/lists/@default/tasks",
        request: fn args, _ctx ->
          [params: [{"maxResults", Map.get(args, "limit", 25)}, {"showCompleted", "false"}]]
        end,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{
                      "tasks" => Map.get(body, "items", []) |> Enum.map(&normalise_task/1)
                    }}
                  end,
        doc: "List the user's tasks on the default list."
      },
      "tasks.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@tasks_base}/lists/@default/tasks",
        request: fn args, _ctx ->
          body =
            %{"title" => args["title"]}
            |> maybe_put_kv("notes", Map.get(args, "notes"))
            |> maybe_put_kv("due",   Map.get(args, "due"))

          [json: body]
        end,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"task_id" => body["id"], "title" => body["title"]}}
                  end,
        doc: "Create a task on the default Google Tasks list."
      }
    }
  end

  defp normalise_task(%{} = item) do
    %{
      "id"     => item["id"],
      "title"  => item["title"],
      "notes"  => item["notes"],
      "due"    => item["due"],
      "status" => item["status"]
    }
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
