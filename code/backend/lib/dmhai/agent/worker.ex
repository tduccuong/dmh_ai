defmodule Dmhai.Agent.Worker do
  @moduledoc """
  Agentic tool-calling loop used by detached worker tasks.

  Uses a dedicated tool-compatible model configured via
  admin_cloud_settings["workerModel"] (format: "provider::model"),
  defaulting to "ollama_cloud::glm-5:cloud".

  Loop:
    1. Call LLM with full message history and all available tools.
    2. tool_calls response → execute each tool, append results, loop (max @max_iter).
    3. Text response → return {:ok, text}.

  Caller (UserAgent.spawn_worker task_fn) writes result to session DB
  and notifies user via MsgGateway.
  """

  alias Dmhai.Agent.{AgentSettings, LLM, MasterBuffer}
  alias Dmhai.Tools.Registry, as: ToolRegistry
  require Logger

  @max_iter 10

  # ─── Public API ────────────────────────────────────────────────────────────

  @doc """
  Run the agentic tool loop.

  - `task`    — plain-text description of what to accomplish.
  - `context` — map with at least `%{user_id: ..., session_id: ...}`.

  LLM routing is determined entirely by the model string (provider::model).
  Cloud key is resolved from the admin accounts pool by the LLM module.
  """
  @spec run(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def run(task, context) do
    model = AgentSettings.worker_model()
    tools = ToolRegistry.all_definitions()
    messages = [%{role: "user", content: task}]

    Logger.info("[Worker] starting model=#{model} task=#{String.slice(task, 0, 80)}")
    result = loop(messages, tools, model, context, @max_iter)

    # Write result to master_buffer for the Master Agent to pick up
    case result do
      {:ok, text} ->
        summary = String.slice(text, 0, 200)
        MasterBuffer.append(context.session_id, context.user_id, text, summary)

      {:error, reason} ->
        MasterBuffer.append(
          context.session_id, context.user_id,
          "Worker error: #{inspect(reason)}",
          "Worker failed: #{inspect(reason)}"
        )
    end

    result
  end

  # ─── Private ───────────────────────────────────────────────────────────────

  defp loop(_messages, _tools, model, _ctx, 0) do
    Logger.warning("[Worker] max iterations reached model=#{model}")
    {:ok, "I reached the maximum number of tool-call steps. The task may be incomplete."}
  end

  defp loop(messages, tools, model, ctx, remaining) do
    case LLM.call(model, messages, tools: tools) do
      {:ok, {:tool_calls, calls}} ->
        Logger.info("[Worker] executing #{length(calls)} tool(s) remaining=#{remaining}")
        assistant_msg = %{role: "assistant", content: "", tool_calls: calls}

        tool_result_msgs =
          Enum.map(calls, fn call ->
            name = get_in(call, ["function", "name"]) || ""
            args = get_in(call, ["function", "arguments"]) || %{}
            tool_call_id = call["id"] || ""

            Logger.info("[Worker] tool=#{name} args=#{inspect(args, limit: 200)}")

            content =
              case ToolRegistry.execute(name, args, ctx) do
                {:ok, result} -> format_tool_result(result)
                {:error, reason} -> "Error: #{reason}"
              end

            %{role: "tool", content: content, tool_call_id: tool_call_id}
          end)

        new_messages = messages ++ [assistant_msg] ++ tool_result_msgs
        loop(new_messages, tools, model, ctx, remaining - 1)

      {:ok, text} when is_binary(text) and text != "" ->
        Logger.info("[Worker] done chars=#{String.length(text)}")
        {:ok, text}

      {:ok, ""} ->
        Logger.warning("[Worker] empty response, stopping")
        {:ok, "The agent finished but produced no output."}

      {:error, reason} ->
        Logger.error("[Worker] LLM error: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp format_tool_result(result) when is_binary(result), do: result

  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: Jason.encode!(result, pretty: true)

  defp format_tool_result(result), do: inspect(result)

end
