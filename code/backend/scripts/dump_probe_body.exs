# Dump the exact request body + Bearer key the LLM module would send to
# Ollama Cloud, so we can curl it directly without booting the app twice.
#
# Run with:
#   DB_PATH=~/.dmhai/db/chat.db mix run scripts/dump_probe_body.exs
#
# Outputs:
#   /tmp/probe_body.json   — full body (messages + tools + model placeholder)
#   /tmp/probe_token       — Bearer token (one line, no newline)

alias Dmhai.Agent.{AgentSettings, ContextEngine}
alias Dmhai.Tools.Registry, as: ToolsRegistry

user_msg =
  System.get_env("PROBE_MSG") ||
    "create a new deal in bitrix24 via this inboud webhook: https://quantumkant.bitrix24.de/rest/1/t1t116c7146hqcy3/"

session_data = %{
  "id"       => "probe_session",
  "messages" => [%{"role" => "user", "content" => user_msg, "ts" => System.os_time(:millisecond)}],
  "context"  => %{},
  "mode"     => "assistant"
}

messages =
  ContextEngine.build_assistant_messages(session_data,
    user_id:      "probe_user",
    profile:      "",
    active_tasks: [],
    recent_done:  [],
    files:        []
  )

tools = ToolsRegistry.all_definitions()
wrapped_tools = Enum.map(tools, fn t -> %{type: "function", function: t} end)

body = %{
  model:    "__MODEL__",
  messages: messages,
  stream:   false,
  tools:    wrapped_tools
}

_ = AgentSettings  # silence alias-unused warning
settings_row =
  Dmhai.Repo
  |> Ecto.Adapters.SQL.query!("SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"])

settings =
  case settings_row.rows do
    [[v] | _] -> Jason.decode!(v || "{}")
    _ -> %{}
  end

accounts = settings["accounts"] || []
account  = Enum.find(accounts, fn a -> is_binary(a["apiKey"]) and a["apiKey"] != "" end) ||
            Enum.at(accounts, 0)
api_key  = (account && (account["apiKey"] || account["key"]) || "") |> String.trim()

File.write!("/tmp/probe_body.json", Jason.encode!(body))
File.write!("/tmp/probe_token", api_key)

IO.puts("body bytes: #{File.stat!("/tmp/probe_body.json").size}")
IO.puts("token len:  #{String.length(api_key)}")
IO.puts("user msg:   #{user_msg}")
