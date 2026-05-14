# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Tools do
  import Plug.Conn
  alias DmhAi.Tools.Registry
  require Logger

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # GET /tools — return all tool definitions in OpenAI function-calling format
  def get_tools(conn, _user) do
    json(conn, 200, %{tools: Registry.all_definitions()})
  end

  # POST /tools/execute — run a tool by name.
  #
  # Body: { "name": "<tool>", "args": {...},
  #         "task_id": "<id>" (optional — required for write verbs
  #                           per Primitive 0.3 Rule 2),
  #         "tool_call_id": "<id>" (optional — used as the step_seq
  #                                 for idempotency-key derivation;
  #                                 defaults to a random unique id) }
  #
  # Context handed to `Tools.Registry.execute/3` carries BOTH the
  # legacy `:user` map (for handlers that still read user info that
  # way) AND the dispatcher's flat keys (`:user_id`, `:task_id`,
  # `:step_seq`, `:tool_call_id`).
  def post_execute(conn, user) do
    with {:ok, body, conn} <- read_body(conn, length: 1_000_000),
         {:ok, %{"name" => name, "args" => args} = decoded} <- Jason.decode(body) do
      tool_call_id = Map.get(decoded, "tool_call_id") || random_tool_call_id()

      uid = user[:id] || user["id"]

      context = %{
        user:         %{id: uid, role: user[:role] || user["role"]},
        user_id:      uid,
        task_id:      Map.get(decoded, "task_id"),
        step_seq:     tool_call_id,
        tool_call_id: tool_call_id
      }

      Logger.info("[TOOL] user=#{uid} tool=#{name}")

      case Registry.execute(name, args, context) do
        {:ok, result} -> json(conn, 200, %{ok: true, result: result})
        {:error, reason} -> json(conn, 400, %{ok: false, error: reason})
      end
    else
      {:ok, body, conn} when is_binary(body) ->
        json(conn, 400, %{error: "Request must include name and args"})

      {:error, %Jason.DecodeError{} = e} ->
        json(conn, 400, %{error: "Invalid JSON: #{Exception.message(e)}"})

      _ ->
        json(conn, 400, %{error: "Request must include name and args"})
    end
  end

  defp random_tool_call_id do
    "tc-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
