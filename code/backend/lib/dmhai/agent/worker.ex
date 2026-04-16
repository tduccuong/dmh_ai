# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Worker do
  @moduledoc """
  Agentic tool-calling loop used by detached worker tasks.

  Uses a dedicated tool-compatible model configured via
  admin_cloud_settings["workerModel"] (format: "provider::model").

  Loop:
    1. Drain any {:subtask_result, output} messages from the mailbox.
       In periodic mode, history is reset to [system + task + latest_result]
       at each drain so prior-cycle tool calls do not accumulate.
    2. Apply rolling-summary compaction if messages exceed system + N + M + 5.
       The rolling summary lives in ctx[:rolling_summary], never in the message
       list, so it is never re-summarised on the next compaction pass.
    3. Inject the rolling summary as a transient prefix before the LLM call.
    4. Call LLM with the message list and all available tools.
    5. tool_calls → execute tools, checkpoint state to DB, loop.
       - If declare_periodic is called, iteration cap is lifted.
       - Otherwise, capped at AgentSettings.worker_max_iter() (default 20).
    6. Text response → return {:ok, text}.

  State is persisted to worker_state table after every iteration so a
  crash or restart can resume from the last checkpoint.
  """

  alias Dmhai.Agent.{AgentSettings, LLM, MasterBuffer, Police, TokenTracker, WorkerState}
  alias Dmhai.Tools.Registry, as: ToolRegistry
  require Logger

  # Max consecutive Police rejections before giving up.
  @max_consecutive_rejections 3

  defp compactor_model, do: AgentSettings.compactor_model()

  # How long to block waiting for a {:subtask_result} before giving up.
  @subtask_wait_ms :timer.minutes(5)

  # Summarise tool results larger than this before injecting into history.
  @summarize_threshold Application.compile_env(:dmhai, [:worker, :summarize_threshold], 5_000)

  # ─── Public API ────────────────────────────────────────────────────────────

  @system_prompt """
  You are a focused worker agent, operating within the scope of DMH-AI ecosystem. Complete the task given to you using the tools available.

  Available tools and when to use them:
  - bash             — run shell commands; always write commands that produce concise output — use grep, awk, head -n, cut to filter verbose dumps; avoid commands that print large raw tables
  - write_file / read_file / list_dir — file operations
  - web_search       — search the Web using keywords
  - web_fetch        — fetch a URL and read the content
  - calculator       — evaluate math expressions
  - datetime         — get current date/time
  - describe_image   — describe the visual content of an image file (pass the file path); use when you need to understand what an image contains
  - describe_video   — describe the visual content of a video file (pass the file path); extracts frames and returns a structured description
  - parse_document   — extract text from a document file (.pdf, .docx, .odt, .pptx, .epub, .html, etc.) and return it as Markdown
  - spawn_task       — spawn a short-lived background process to run a bash command after an optional delay; the result is returned to you in the NEXT step
  - midjob_notify    — push an update/report to the user mid-task (appears in chat + external platforms)
  - declare_periodic — declare that this is a long-running repeating task; lifts the iteration cap

  **Rules for ONE-OFF tasks**:
  1. Work through the task step by step using bash, web_search, web_fetch, file tools, etc.
  2. Return a clear final summary when done.

  **Rules for PERIODIC tasks** (monitoring, polling, scheduled reports):
  1. Call declare_periodic FIRST — before anything else.
  2. ONLY generate exactly ONE item per cycle on-demand (e.g. one joke, one report) via `spawn_task` e.g., `spawn_task(command: "...", delay_ms: 10000)`. The result WILL be available automatically.
  3. When the result arrives, call `midjob_notify` to deliver it to the user.
  4. Then call `spawn_task` again with the same delay to schedule the next iteration.
  5. NEVER use `sleep` in bash commands or write shell scripts with `while true; sleep N`. That blocks the process. Use `spawn_task` with delay_ms instead.
  6. Never pre-generate content in bulk upfront.
  7. Repeat indefinitely until the user cancels.

  **CRITICAL RULES:**
  1. Language:
     - Always use the **SAME** language as the task description.
     - Never switch to another language unless explicitly asked.
  2. Tool calling:
     - ALWAYS invoke tools via the tool-calling mechanism. Call that does NOT conform to tool schemas is FORBIDDEN.
  3. `web_search` is EXPENSIVE: Only call `web_search` when the task genuinely requires live or recent data:
     - Breaking news, sports scores, stock/crypto prices, weather, recent headlines
     - Current status of a service, platform, website, or system (outages, incidents)
     - Figures that change over time: tax rates, salary tables, laws, regulations, prices, statistics
     - Latest version, recent release, or recent update of a product, tool, or library
     - Anything you are unsure about or that may have changed since your training data
     **Do NOT call** `web_search` for: translation, summarisation, writing help, coding questions you can answer, science, history, math, geography, or well-known stable concepts.
  """

  @doc """
  Start a fresh worker from scratch.
  `context` must contain: user_id, session_id, agent_pid, worker_id, description.
  """
  @spec run(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def run(task, context) do
    model = AgentSettings.worker_model()
    tools = ToolRegistry.all_definitions()
    messages = [
      %{role: "system", content: @system_prompt},
      %{role: "user",   content: task}
    ]

    ctx =
      context
      |> Map.put(:worker_pid, self())
      |> Map.put(:task, task)
      |> Map.put_new(:rolling_summary, nil)

    worker_id = Map.get(ctx, :worker_id, "unknown")
    WorkerState.upsert(worker_id, ctx.session_id, ctx.user_id, task, messages, 0, false, nil, "running")

    Logger.info("[Worker] starting model=#{model} task=#{String.slice(task, 0, 80)}")
    result = loop(messages, tools, model, ctx)

    case result do
      {:ok, text} ->
        MasterBuffer.append(context.session_id, context.user_id, text, nil, worker_id)

      {:error, reason} ->
        MasterBuffer.append(
          context.session_id, context.user_id,
          "__WORKER_ERROR__\n#{worker_error_text(reason)}",
          nil, worker_id
        )
    end

    WorkerState.mark_done(worker_id)
    result
  end

  @doc """
  Resume a worker from a DB checkpoint after a crash or restart.
  `checkpoint` is a map from WorkerState.fetch_running/1.
  `agent_pid` is the UserAgent GenServer PID for progress reporting.
  """
  @spec run_from_checkpoint(map(), pid()) :: {:ok, String.t()} | {:error, term()}
  def run_from_checkpoint(checkpoint, agent_pid) do
    model = AgentSettings.worker_model()
    tools = ToolRegistry.all_definitions()
    messages = normalize_messages(checkpoint.messages)

    ctx = %{
      user_id:         checkpoint.user_id,
      session_id:      checkpoint.session_id,
      worker_pid:      self(),
      agent_pid:       agent_pid,
      worker_id:       checkpoint.worker_id,
      description:     checkpoint.task,
      task:            checkpoint.task,
      iter:            checkpoint.iter,
      periodic:        checkpoint.periodic,
      rolling_summary: checkpoint.rolling_summary
    }

    Logger.info("[Worker] resuming checkpoint id=#{checkpoint.worker_id} iter=#{checkpoint.iter}")
    result = loop(messages, tools, model, ctx)

    case result do
      {:ok, text} ->
        MasterBuffer.append(checkpoint.session_id, checkpoint.user_id, text, nil, checkpoint.worker_id)

      {:error, reason} ->
        MasterBuffer.append(
          checkpoint.session_id, checkpoint.user_id,
          "__WORKER_ERROR__\n#{worker_error_text(reason)}",
          nil, checkpoint.worker_id
        )
    end

    WorkerState.mark_done(checkpoint.worker_id)
    result
  end

  # ─── Private ───────────────────────────────────────────────────────────────

  # ctx carries loop-control state:
  #   :iter            — tool-call rounds completed (default 0)
  #   :periodic        — true once declare_periodic has been called (default false)
  #   :worker_pid      — this process's PID
  #   :task            — original task text (for periodic history reset)
  #   :rolling_summary — accumulated compaction summary (nil initially)

  defp loop(messages, tools, model, ctx) do
    messages = drain_subtask_results(messages, ctx)
    {messages, ctx} = maybe_compact_worker_messages(messages, ctx)

    iter     = Map.get(ctx, :iter, 0)
    periodic = Map.get(ctx, :periodic, false)
    max_iter = AgentSettings.worker_max_iter()

    if not periodic and iter >= max_iter do
      Logger.warning("[Worker] max iterations (#{max_iter}) reached model=#{model}")
      {:ok, "I reached the maximum number of tool-call steps (#{max_iter}). The task may be incomplete."}
    else
      worker_id   = Map.get(ctx, :worker_id, "unknown")
      description = Map.get(ctx, :description, "")

      on_tokens = fn rx, tx ->
        TokenTracker.add_worker(ctx.session_id, ctx.user_id, worker_id, description, rx, tx)
      end

      Dmhai.SysLog.log("[WORKER] iter=#{iter} id=#{worker_id} periodic=#{periodic} msgs=#{length(messages)} summary=#{inspect(Map.get(ctx, :rolling_summary))|> String.slice(0,80)}\n  #{log_worker_messages(messages)}")

      # Inject rolling summary as a transient prefix — not stored in messages.
      effective_messages = inject_rolling_summary(messages, ctx)

      case LLM.call(model, effective_messages, tools: tools, on_tokens: on_tokens) do
        {:ok, {:tool_calls, calls}} ->
          Logger.info("[Worker] executing #{length(calls)} tool(s) iter=#{iter} periodic=#{periodic}")
          call_names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
          Dmhai.SysLog.log("[WORKER] id=#{worker_id} iter=#{iter} → tool_calls=[#{call_names}]")

          case Police.check_tool_calls(calls, messages) do
            {:rejected, reason} ->
              consec = Map.get(ctx, :consecutive_rejections, 0) + 1
              if consec >= @max_consecutive_rejections do
                Logger.error("[Worker] Police: max rejections reached (#{reason}), stopping")
                {:error, "Repeated policy violation: #{reason}"}
              else
                rejection_msg = %{role: "user", content: Police.rejection_msg()}
                new_ctx = Map.put(ctx, :consecutive_rejections, consec)
                loop(messages ++ [rejection_msg], tools, model, new_ctx)
              end

            :ok ->
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

              args_str = Jason.encode!(args) |> String.slice(0, 200)
              Dmhai.SysLog.log("[WORKER] id=#{worker_id} tool=#{name} args=#{args_str}")

              content =
                case ToolRegistry.execute(name, args, ctx) do
                  {:ok, result}    -> maybe_summarize_result(format_tool_result(result))
                  {:error, reason} -> "Error: #{reason}"
                end

              Dmhai.SysLog.log("[WORKER] id=#{worker_id} tool=#{name} result=#{String.slice(content, 0, 300)}")

              if agent_pid = Map.get(ctx, :agent_pid) do
                send(agent_pid, {:worker_progress, worker_id, "#{name}: #{String.slice(content, 0, 150)}"})
              end

              %{role: "tool", content: content, tool_call_id: tool_call_id}
            end)

          new_messages = messages ++ [assistant_msg] ++ tool_result_msgs
          new_ctx      =
            ctx
            |> Map.put(:iter, iter + 1)
            |> Map.put(:periodic, new_periodic)
            |> Map.put(:consecutive_rejections, 0)

          # Checkpoint to DB so a restart can resume from here.
          # Uses checkpoint/5 (not upsert) so status is not clobbered —
          # 'recovering' stays 'recovering', preventing double-claim on idle-timeout restart.
          WorkerState.checkpoint(
            worker_id, new_messages,
            iter + 1, new_periodic, Map.get(new_ctx, :rolling_summary)
          )

          loop(new_messages, tools, model, new_ctx)
          end  # case Police.check_tool_calls

        {:ok, text} when is_binary(text) and text != "" ->
          Dmhai.SysLog.log("[WORKER] id=#{worker_id} iter=#{iter} → text(#{String.length(text)} chars): #{String.slice(text, 0, 200)}")

          case Police.check_text(text, ctx) do
            {:rejected, reason} ->
              consec = Map.get(ctx, :consecutive_rejections, 0) + 1
              if consec >= @max_consecutive_rejections do
                Logger.error("[Worker] Police: max rejections reached (#{reason}), stopping")
                {:error, "Repeated policy violation: #{reason}"}
              else
                rejection_msg = %{role: "user", content: Police.rejection_msg()}
                assistant_msg = %{role: "assistant", content: text}
                new_ctx = Map.put(ctx, :consecutive_rejections, consec)
                loop(messages ++ [assistant_msg, rejection_msg], tools, model, new_ctx)
              end

            :ok ->
          if Map.get(ctx, :periodic, false) do
            # In periodic mode the LLM sometimes returns a text summary after
            # scheduling the next spawn_task. Block until the result arrives.
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
          end  # case Police.check_text

        {:ok, ""} ->
          Logger.warning("[Worker] empty response, stopping")
          {:ok, "The agent finished but produced no output."}

        {:error, reason} ->
          Logger.error("[Worker] LLM error: #{inspect(reason)}")
          Dmhai.SysLog.log("[WORKER] id=#{worker_id} iter=#{iter} → ERROR: #{inspect(reason)}")
          {:error, inspect(reason)}
      end
    end
  end

  # ─── Context compaction ────────────────────────────────────────────────────

  # Rolling-summary compaction. Triggered when messages grow beyond system + N + M + 5.
  # Old spillover messages are incorporated into a rolling_summary stored in ctx,
  # never injected back into the message list — so they are never re-summarised.
  defp maybe_compact_worker_messages(messages, ctx) do
    n     = AgentSettings.worker_context_n()
    m     = AgentSettings.worker_context_m()
    total = length(messages)

    if total <= 1 + n + m + 5 do
      {messages, ctx}
    else
      [system_msg | rest] = messages
      old_count = total - 1 - n - m
      old    = Enum.take(rest, old_count)
      middle = Enum.slice(rest, old_count, n)
      recent = Enum.take(rest, -m)

      Logger.info("[Worker] compacting context old=#{old_count} middle=#{n} recent=#{m}")

      new_summary  = update_rolling_summary(old, Map.get(ctx, :rolling_summary))
      new_messages = [system_msg] ++ stub_tool_results(middle) ++ recent
      new_ctx      = Map.put(ctx, :rolling_summary, new_summary)
      {new_messages, new_ctx}
    end
  end

  # Inject the rolling summary as a transient message pair right after the system
  # prompt so the LLM has context of prior work. Not stored in the message list.
  defp inject_rolling_summary(messages, ctx) do
    case Map.get(ctx, :rolling_summary) do
      s when s in [nil, ""] ->
        messages

      summary ->
        [system_msg | rest] = messages
        [system_msg,
         %{role: "user",      content: "[Prior work summary]\n#{summary}"},
         %{role: "assistant", content: "Understood, continuing from prior work."}
         | rest]
    end
  end

  # Incorporate old spillover messages into the rolling summary.
  # Passes only the new messages to the compactor; the existing summary is
  # provided as context so it is updated rather than regenerated from scratch.
  defp update_rolling_summary([], current_summary), do: current_summary

  defp update_rolling_summary(old_messages, current_summary) do
    flat = flatten_for_compaction(old_messages)

    instruction =
      if current_summary && current_summary != "" do
        "Update the following summary with the new worker activity below. " <>
          "Keep it dense and factual. Capture only what changed or was newly accomplished.\n\n" <>
          "Current summary:\n#{current_summary}\n\nNew activity:"
      else
        "Summarise this worker agent's activity. Include: tasks attempted, key results, " <>
          "current state, any errors. Be dense and factual. Omit repetitive tool outputs."
      end

    compaction_msgs = flat ++ [%{role: "user", content: instruction}]

    case LLM.call(compactor_model(), compaction_msgs) do
      {:ok, new_summary} when is_binary(new_summary) and new_summary != "" ->
        new_summary

      _ ->
        Logger.warning("[Worker] rolling summary update failed, keeping old summary")
        current_summary
    end
  end

  # Flatten messages to simple role/content pairs for the compactor LLM.
  defp flatten_for_compaction(messages) do
    Enum.flat_map(messages, fn msg ->
      role    = msg[:role]       || msg["role"]       || "user"
      content = msg[:content]    || msg["content"]    || ""
      calls   = msg[:tool_calls] || msg["tool_calls"]

      cond do
        role == "assistant" and is_list(calls) and calls != [] ->
          names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
          [%{role: "assistant", content: "[called tools: #{names}]"}]

        role == "tool" ->
          if content != "", do: [%{role: "user", content: "[tool result] #{content}"}], else: []

        content == "" ->
          []

        true ->
          [%{role: role, content: content}]
      end
    end)
  end

  # Replace tool result content with a size stub to save context tokens.
  # Handles both atom-keyed and string-keyed maps (latter from DB recovery).
  defp stub_tool_results(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      if role == "tool" do
        content = to_string(msg[:content] || msg["content"] || "")
        stub    = "[truncated: #{String.length(content)} chars]"
        if Map.has_key?(msg, :role) do
          %{msg | content: stub}
        else
          Map.put(msg, "content", stub)
        end
      else
        msg
      end
    end)
  end

  # Drain pending subtask results (non-blocking). In periodic mode, reset the
  # full message history to [system + task + latest_result] so prior-cycle
  # tool calls do not accumulate across iterations.
  defp drain_subtask_results(messages, ctx) do
    collect_results(messages, ctx, [])
  end

  defp collect_results(messages, ctx, results) do
    receive do
      {:subtask_result, output} ->
        collect_results(messages, ctx, results ++ [maybe_summarize_result(output)])
    after 0 ->
      if results == [] do
        messages
      else
        periodic = Map.get(ctx, :periodic, false)
        if periodic do
          # Drop all accumulated history — each cycle starts fresh.
          [system_msg | _] = messages
          task_text  = Map.get(ctx, :task, "")
          last_output = List.last(results)
          [
            system_msg,
            %{role: "user", content: task_text},
            %{role: "user", content: "[Scheduled task result]\n#{last_output}"}
          ]
        else
          extra = Enum.map(results, fn r ->
            %{role: "user", content: "[Scheduled task result]\n#{r}"}
          end)
          messages ++ extra
        end
      end
    end
  end

  # Block waiting for a single {:subtask_result} with a wall-clock deadline.
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

  defp format_tool_result(result) when is_binary(result), do: result

  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: Jason.encode!(result, pretty: true)

  defp format_tool_result(result), do: inspect(result)

  # Summarise large tool results before injecting into history.
  # Falls back to hard truncation if the summariser fails.
  defp maybe_summarize_result(text) when is_binary(text) do
    max_chars = AgentSettings.max_tool_result_chars()
    if String.length(text) <= @summarize_threshold do
      text
    else
      model   = compactor_model()
      excerpt = String.slice(text, 0, max_chars)
      prompt  = [
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
          truncate_tool_result(text, max_chars)
      end
    end
  end

  defp truncate_tool_result(text, max_chars) when is_binary(text) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <>
        "\n[truncated: #{String.length(text) - max_chars} chars omitted]"
    else
      text
    end
  end

  # Convert DB-loaded messages (string-keyed maps from Jason.decode) back to
  # atom-keyed maps so pattern matching in loop and tools works correctly.
  defp normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{"role" => role} = msg ->
        normalized = %{
          role:    role,
          content: msg["content"] || ""
        }

        normalized =
          case msg["tool_calls"] do
            nil -> normalized
            tc  -> Map.put(normalized, :tool_calls, tc)
          end

        case msg["tool_call_id"] do
          nil -> normalized
          id  -> Map.put(normalized, :tool_call_id, id)
        end

      msg ->
        # Already atom-keyed or unknown format — pass through.
        msg
    end)
  end

  defp normalize_messages(_), do: []

  defp worker_error_text(reason) when is_binary(reason), do: reason
  defp worker_error_text(reason), do: inspect(reason)

  defp log_worker_messages(messages) do
    non_sys = Enum.reject(messages, fn m -> (m[:role] || m["role"]) == "system" end)
    parts = Enum.map(non_sys, fn m ->
      role    = m[:role]       || m["role"]       || "?"
      content = m[:content]    || m["content"]    || ""
      calls   = m[:tool_calls] || m["tool_calls"] || []
      if is_list(calls) and calls != [] do
        names = Enum.map_join(calls, ",", fn c -> get_in(c, ["function", "name"]) || "?" end)
        "[#{role}→#{names}]"
      else
        snippet = content |> to_string() |> String.slice(0, 80) |> String.replace("\n", "↵")
        "[#{role}]#{snippet}"
      end
    end)
    result = Enum.join(parts, " | ")
    if String.length(result) > 1000, do: String.slice(result, 0, 1000) <> "…", else: result
  end
end
