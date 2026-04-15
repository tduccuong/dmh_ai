defmodule Dmhai.Handlers.Tools do
  import Plug.Conn
  alias Dmhai.Tools.Registry
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

  # POST /tools/execute — run a tool by name
  def post_execute(conn, user) do
    with {:ok, body, conn} <- read_body(conn, length: 1_000_000),
         {:ok, %{"name" => name, "args" => args}} <- Jason.decode(body) do
      context = %{user: %{id: user["id"], role: user["role"]}}
      Logger.info("[TOOL] user=#{user["id"]} tool=#{name}")

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
end
