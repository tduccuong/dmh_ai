# Diagnostic: send the EXACT chain-start context (system prompt +
# tool catalog + a single user message) to the assistant model and
# print whatever it emits. Helps us see what the model actually
# does given the current prompt for a known-tricky input.
#
# Run with:
#   DB_PATH=~/.dmhai/db/chat.db mix run scripts/probe_model.exs

alias Dmhai.Agent.{AgentSettings, ContextEngine, LLM}
alias Dmhai.Tools.Registry, as: ToolsRegistry

user_msg =
  System.get_env("PROBE_MSG") ||
    "create a new deal in bitrix24 via this inboud webhook: https://quantumkant.bitrix24.de/rest/1/t1t116c7146hqcy3/"

# Build a minimal session_data — the same shape `load_session` returns.
# Empty messages + empty context: chain-start state, no prior turns.
session_data = %{
  "id"       => "probe_session_" <> :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false),
  "messages" => [
    %{"role" => "user", "content" => user_msg, "ts" => System.os_time(:millisecond)}
  ],
  "context"  => %{},
  "mode"     => "assistant"
}

llm_messages =
  ContextEngine.build_assistant_messages(session_data,
    user_id:      "probe_user",
    profile:      "",
    active_tasks: [],
    recent_done:  [],
    files:        []
  )

tools = ToolsRegistry.all_definitions()

# Override the model via PROBE_MODEL env var (plain or routed form).
# Defaults to whatever AgentSettings.assistant_model() resolves to.
model =
  case System.get_env("PROBE_MODEL") do
    nil ->
      AgentSettings.assistant_model()

    plain ->
      if String.contains?(plain, "::") do
        plain
      else
        pool = if String.ends_with?(plain, "-cloud") or String.ends_with?(plain, ":cloud"),
                  do: "cloud", else: "local"
        "ollama::#{pool}::#{plain}"
      end
  end

IO.puts("\n=== Probe ===")
IO.puts("Model:     #{model}")
IO.puts("Messages:  #{length(llm_messages)}")
IO.puts("Tools:     #{length(tools)}")
IO.puts("User msg:  #{user_msg}")

system_msg = Enum.find(llm_messages, &(&1[:role] == "system" or &1["role"] == "system"))

if system_msg do
  prompt_chars = String.length(system_msg.content || system_msg["content"] || "")
  IO.puts("System prompt length: #{prompt_chars} chars")
end

# Optional dump: write the full system prompt + the rendered messages
# JSON to a file so a human can review what the model actually saw.
if dump_path = System.get_env("PROBE_DUMP") do
  prompt_text = (system_msg && (system_msg.content || system_msg["content"])) || ""

  user_block =
    llm_messages
    |> Enum.reject(&(&1[:role] == "system" or &1["role"] == "system"))
    |> Enum.map(fn m -> "## #{m[:role] || m["role"]}\n\n#{m[:content] || m["content"]}\n" end)
    |> Enum.join("\n")

  body =
    "# System prompt\n\n" <> prompt_text <>
      "\n\n# Tools (#{length(tools)})\n\n" <>
      Enum.map_join(tools, "\n", fn t -> "- `#{t.name}` — #{String.slice(t.description || "", 0, 80)}…" end) <>
      "\n\n# Conversation\n\n" <> user_block

  File.write!(dump_path, body)
  IO.puts("Dumped to: #{dump_path}")
end

IO.puts("\n=== Calling LLM ===\n")

result = LLM.call(model, llm_messages, tools: tools)

case result do
  {:ok, text} when is_binary(text) ->
    IO.puts("→ TEXT response (#{String.length(text)} chars):")
    IO.puts(text)

  {:ok, {:tool_calls, calls}} ->
    IO.puts("→ TOOL_CALLS (#{length(calls)} call(s)):")
    Enum.each(calls, fn c ->
      fn_map = c["function"] || %{}
      name   = fn_map["name"]
      args   = fn_map["arguments"]
      IO.puts("  • #{name}(#{Jason.encode!(args)})")
    end)

  {:error, reason} ->
    IO.puts("→ ERROR: #{inspect(reason)}")
end
