# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Worker do
  @moduledoc """
  Agentic tool-calling loop used by detached worker tasks.

  Uses a dedicated tool-compatible model configured via
  admin_cloud_settings["workerModel"] (format: "provider::model"),
  defaulting to "ollama_cloud::glm-5:cloud".

  Loop:
    1. Drain any {:subtask_result, output} messages from the mailbox and
       inject them as user context (non-blocking receive after 0).
    2. Call LLM with full message history and all available tools.
    3. tool_calls response → execute each tool, report progress, loop.
       - If declare_periodic is called, iteration cap is lifted.
       - Otherwise, capped at AgentSettings.worker_max_iter() (default 20).
    4. Text response → return {:ok, text}.

  Caller (UserAgent.spawn_worker task_fn) writes result to session DB
  and notifies user via MsgGateway.
  """

  alias Dmhai.Agent.{AgentSettings, LLM, MasterBuffer}
  alias Dmhai.Tools.Registry, as: ToolRegistry
  require Logger

  # Model used to summarise old worker context — reads from admin settings.
  defp compactor_model, do: AgentSettings.compactor_model()

  # How long to block waiting for a {:subtask_result} before giving up.
  @subtask_wait_ms :timer.minutes(5)

  # If a tool result exceeds this, summarise it with the compactor model first.
  @summarize_threshold Application.compile_env(:dmhai, [:worker, :summarize_threshold], 5_000)

  # Hard cap applied after summarisation fails — absolute last resort.
  @max_tool_result_chars Application.compile_env(:dmhai, [:worker, :max_tool_result_chars], 8_000)

  # ─── Public API ────────────────────────────────────────────────────────────

  @doc """
  Run the agentic tool loop.

  - `task`    — plain-text description of what to accomplish.
  - `context` — map with at least `%{user_id: ..., session_id: ...,
                  agent_pid: pid(), worker_id: String.t()}`.

  LLM routing is determined entirely by the model string (provider::model).
  Cloud key is resolved from the admin accounts pool by the LLM module.
  """
  @system_prompt """
  You are a focused worker agent. Complete the task given to you using the tools available.

  Available tools and when to use them:
  - bash          — run shell commands; always write commands that produce concise output — use grep, awk, head -n, cut to filter verbose dumps; avoid commands that print large raw tables
  - write_file / read_file / list_dir — file operations
  - web_fetch     — fetch and read a URL
  - calculator    — evaluate math expressions
  - datetime      — get current date/time
  - spawn_task    — spawn a short-lived background process to run a bash command after an optional delay; the result is returned to you in the NEXT step
  - midjob_notify — push an update/report to the user mid-task (appears in chat + external platforms)
  - declare_periodic — declare that this is a long-running repeating task; lifts the iteration cap

  Rules for PERIODIC tasks (monitoring, polling, scheduled reports):
  1. Call declare_periodic FIRST — before anything else.
  2. NEVER use `sleep` in bash commands or write shell scripts with `while true; sleep N`. That blocks the process.
  3. Instead, use spawn_task with delay_ms to schedule each timed step:
       spawn_task(command: "...", delay_ms: 10000)
     The result arrives in your next step automatically.
  4. When the result arrives, call midjob_notify to deliver it to the user.
  5. Then spawn_task again with the same delay to schedule the next iteration.
  6. Repeat indefinitely until the user cancels.

  Rules for ONE-OFF tasks:
  - Work through the task step by step using bash, web_fetch, file tools, etc.
  - Return a clear final summary when done.
  """

  @spec run(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def run(task, context) do
    model = AgentSettings.worker_model()
    tools = ToolRegistry.all_definitions()
    messages = [
      %{role: "system", content: @system_prompt},
      %{role: "user", content: task}
    ]

    # Expose this process's PID so spawn_task can report results back
    ctx = Map.put(context, :worker_pid, self())

    Logger.info("[Worker] starting model=#{model} task=#{String.slice(task, 0, 80)}")
    result = loop(messages, tools, model, ctx)

    # Write final result to master_buffer for the Master Agent to pick up.
    # For periodic workers that never return a final text, this path is only
    # reached if the worker is cancelled or crashes out of the loop.
    case result do
      {:ok, text} ->
        worker_id = Map.get(context, :worker_id)
        # No summary — notification fires after master responds (see trigger_master_from_buffer)
        MasterBuffer.append(context.session_id, context.user_id, text, nil, worker_id)

      {:error, reason} ->
        worker_id = Map.get(context, :worker_id)
        MasterBuffer.append(
          context.session_id, context.user_id,
          "Worker error: #{inspect(reason)}",
          nil,
          worker_id
        )
    end

    result
  end

  # ─── Private ───────────────────────────────────────────────────────────────

  # ctx carries loop-control state in addition to user/session context:
  #   :iter     — number of tool-call rounds completed so far (default 0)
  #   :periodic — true once declare_periodic has been called (default false)
  #   :worker_pid — this process's PID (set in run/2)

  defp loop(messages, tools, model, ctx) do
    # Pull any pending sub-task results into the message context first
    messages = drain_subtask_results(messages)
    # Trim context when it grows too large (periodic workers accumulate fast)
    messages = maybe_compact_worker_messages(messages)

    iter     = Map.get(ctx, :iter, 0)
    periodic = Map.get(ctx, :periodic, false)
    max_iter = AgentSettings.worker_max_iter()

    if not periodic and iter >= max_iter do
      Logger.warning("[Worker] max iterations (#{max_iter}) reached model=#{model}")
      {:ok, "I reached the maximum number of tool-call steps (#{max_iter}). The task may be incomplete."}
    else
      case LLM.call(model, messages, tools: tools) do
        {:ok, {:tool_calls, calls}} ->
          Logger.info("[Worker] executing #{length(calls)} tool(s) iter=#{iter} periodic=#{periodic}")

          # detect declare_periodic before execution so the flag is set for this round
          declaring_periodic = Enum.any?(calls, fn c ->
            get_in(c, ["function", "name"]) == "declare_periodic"
          end)

          new_periodic = periodic or declaring_periodic

          if declaring_periodic and not periodic do
            Logger.info("[Worker] periodic mode declared — iteration cap lifted")
          end

          assistant_msg = %{role: "assistant", content: "", tool_calls: calls}

          tool_result_msgs =
            Enum.map(calls, fn call ->
              name         = get_in(call, ["function", "name"]) || ""
              args         = get_in(call, ["function", "arguments"]) || %{}
              tool_call_id = call["id"] || ""

              Logger.info("[Worker] tool=#{name} args=#{inspect(args, limit: 200)}")

              content =
                case ToolRegistry.execute(name, args, ctx) do
                  {:ok, result}    -> maybe_summarize_result(format_tool_result(result))
                  {:error, reason} -> "Error: #{reason}"
                end

              # Report progress to the parent UserAgent
              if agent_pid = Map.get(ctx, :agent_pid) do
                worker_id = Map.get(ctx, :worker_id, "unknown")
                send(agent_pid, {:worker_progress, worker_id, "#{name}: #{String.slice(content, 0, 150)}"})
              end

              %{role: "tool", content: content, tool_call_id: tool_call_id}
            end)

          new_messages = messages ++ [assistant_msg] ++ tool_result_msgs
          new_ctx      = ctx |> Map.put(:iter, iter + 1) |> Map.put(:periodic, new_periodic)
          loop(new_messages, tools, model, new_ctx)

        {:ok, text} when is_binary(text) and text != "" ->
          if Map.get(ctx, :periodic, false) do
            # In periodic mode the LLM sometimes returns a text summary after
            # scheduling the next spawn_task.  Don't exit — block until the
            # scheduled result arrives, then continue the loop.
            Logger.info("[Worker] periodic: LLM returned text, waiting for next subtask result")
            assistant_msg = %{role: "assistant", content: text}
            deadline = System.monotonic_time(:millisecond) + @subtask_wait_ms

            case await_subtask_result(deadline) do
              {:ok, output} ->
                user_msg = %{role: "user", content: "[Scheduled task result]\n#{output}"}
                loop(messages ++ [assistant_msg, user_msg], tools, model, ctx)

              :timeout ->
                Logger.warning("[Worker] periodic: timed out waiting for subtask result, stopping")
                {:ok, text}
            end
          else
            Logger.info("[Worker] done chars=#{String.length(text)}")
            {:ok, text}
          end

        {:ok, ""} ->
          Logger.warning("[Worker] empty response, stopping")
          {:ok, "The agent finished but produced no output."}

        {:error, reason} ->
          Logger.error("[Worker] LLM error: #{inspect(reason)}")
          {:error, inspect(reason)}
      end
    end
  end

  # ─── Context compaction ────────────────────────────────────────────────────

  # 3-tier trim applied at the top of every loop iteration.
  # Triggered once messages grow beyond system + N + M + 5.
  # Tier 1 (oldest):  LLM-summarised into a single context exchange.
  # Tier 2 (middle):  tool result content stubbed to "[N chars, truncated]".
  # Tier 3 (recent):  last M messages left untouched.
  defp maybe_compact_worker_messages(messages) do
    n = AgentSettings.worker_context_n()
    m = AgentSettings.worker_context_m()
    total = length(messages)

    # Need at least 6 messages in the old tier to be worth summarising
    if total <= 1 + n + m + 5 do
      messages
    else
      [system_msg | rest] = messages
      old_count = total - 1 - n - m

      old    = Enum.take(rest, old_count)
      middle = Enum.slice(rest, old_count, n)
      recent = Enum.take(rest, -m)

      Logger.info("[Worker] compacting context old=#{old_count} middle=#{n} recent=#{m}")

      [system_msg] ++ summarize_old(old) ++ stub_tool_results(middle) ++ recent
    end
  end

  # Flatten old messages to role/content pairs and ask the compactor to summarise.
  # Falls back to stubbing if the LLM call fails.
  defp summarize_old([]), do: []

  defp summarize_old(old_messages) do
    flat =
      Enum.flat_map(old_messages, fn msg ->
        role    = msg[:role]    || msg["role"]    || "user"
        content = msg[:content] || msg["content"] || ""
        calls   = msg[:tool_calls] || msg["tool_calls"]

        cond do
          role == "assistant" and is_list(calls) and calls != [] ->
            names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
            [%{role: "assistant", content: "[called tools: #{names}]"}]

          # Convert tool-result messages to user-role — Gemini rejects role="tool"
          # messages without a valid paired function call in the same request.
          role == "tool" ->
            if content != "", do: [%{role: "user", content: "[tool result] #{content}"}], else: []

          content == "" ->
            []

          true ->
            [%{role: role, content: content}]
        end
      end)

    compaction_msgs =
      flat ++
        [%{
          role: "user",
          content:
            "Summarise this worker agent's activity. Include: tasks attempted, key results, " <>
              "current state, any errors. Be dense and factual. Omit repetitive tool outputs."
        }]

    case LLM.call(compactor_model(), compaction_msgs) do
      {:ok, summary} when is_binary(summary) and summary != "" ->
        [
          %{role: "user",    content: "[Worker activity summary]\n#{summary}"},
          %{role: "assistant", content: "Understood, I have context of prior work."}
        ]

      _ ->
        Logger.warning("[Worker] context summarisation failed, stubbing instead")
        stub_tool_results(old_messages)
    end
  end

  # Replace tool result content with a size stub to save context tokens.
  defp stub_tool_results(messages) do
    Enum.map(messages, fn
      %{role: "tool"} = msg ->
        content = to_string(msg[:content] || "")
        %{msg | content: "[truncated: #{String.length(content)} chars]"}
      msg ->
        msg
    end)
  end

  # Block waiting for {:subtask_result} using a wall-clock deadline so
  # stray messages are discarded without blowing the total wait time.
  defp await_subtask_result(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {:subtask_result, output} -> {:ok, output}
        _other                    -> await_subtask_result(deadline)
      after
        remaining -> :timeout
      end
    end
  end

  # Drain all pending {:subtask_result, output} messages from the mailbox
  # without blocking (after 0).  Each result is injected as a user message
  # so the LLM sees it in the next call.
  defp drain_subtask_results(messages) do
    receive do
      {:subtask_result, output} ->
        msg = %{role: "user", content: "[Scheduled task result]\n#{maybe_summarize_result(output)}"}
        drain_subtask_results(messages ++ [msg])
    after 0 ->
      messages
    end
  end

  defp format_tool_result(result) when is_binary(result), do: result

  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: Jason.encode!(result, pretty: true)

  defp format_tool_result(result), do: inspect(result)

  # If the result is large, summarise it with the compactor model so the LLM
  # gets key facts without bloating the context. Falls back to hard truncation
  # when the summarisation call fails.
  defp maybe_summarize_result(text) when is_binary(text) do
    if String.length(text) <= @summarize_threshold do
      text
    else
      model = compactor_model()
      # Feed at most the hard cap to the summariser — no point sending more.
      excerpt = String.slice(text, 0, @max_tool_result_chars)
      prompt = [
        %{role: "user",
          content:
            "Extract only the essential facts and metrics from this tool output. " <>
            "3-5 lines max. Focus on what a task agent would need to act on. " <>
            "Output just the facts, no preamble.\n\n#{excerpt}"}
      ]

      case LLM.call(model, prompt) do
        {:ok, summary} when is_binary(summary) and summary != "" ->
          "[Summarised from #{String.length(text)} chars]\n#{summary}"

        _ ->
          Logger.warning("[Worker] result summarisation failed, truncating instead")
          truncate_tool_result(text)
      end
    end
  end

  defp truncate_tool_result(text) when is_binary(text) do
    if String.length(text) > @max_tool_result_chars do
      String.slice(text, 0, @max_tool_result_chars) <>
        "\n[truncated: #{String.length(text) - @max_tool_result_chars} chars omitted]"
    else
      text
    end
  end
end
