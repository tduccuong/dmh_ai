# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Worker do
  @moduledoc """
  Agentic tool-calling loop for ONE-OFF job execution.

  The worker is fully one-off. Periodicity is the runtime scheduler's
  concern — the scheduler re-spawns a fresh worker for each cycle. The
  worker never knows whether its parent job is periodic.

  PROTOCOL contract: every task MUST end with a call to
  `signal(status, result | reason)`. The signal tool writes a
  `kind='final'` row to worker_status; the runtime picks that up as
  the job's terminal state.

  Loop:
    1. Drain any {:subtask_result, output} messages from the mailbox
       (from async spawn_task calls). Append as user messages.
    2. Apply rolling-summary compaction if messages exceed system + N + M + 5.
    3. Inject the rolling summary as a transient prefix before the LLM call.
    4. Call LLM with the message list and all available tools.
    5. tool_calls → write worker_status rows (tool_call + tool_result),
       execute tools, loop. If the batch includes `signal`, exit.
    6. Text response → Police nudges the model to call signal; after
       @max_consecutive_rejections the runtime synthesises BLOCKED.

  The ctx map MUST contain :job_id. All worker_status rows are keyed by it.
  """

  alias Dmhai.Agent.{AgentSettings, LLM, Police, TokenTracker, WorkerStatus}
  alias Dmhai.Tools.Registry, as: ToolRegistry
  require Logger

  # Max consecutive Police rejections before giving up.
  @max_consecutive_rejections 3

  # Summarise tool results larger than this before injecting into history.
  @summarize_threshold Application.compile_env(:dmhai, [:worker, :summarize_threshold], 5_000)

  defp compactor_model, do: AgentSettings.compactor_model()

  @doc false
  def build_system_prompt(language \\ "en") do
    lang = language || "en"
    now  = DateTime.utc_now() |> DateTime.to_iso8601() |> String.slice(0, 16)

    """
    You are a focused worker agent, operating within the scope of DMH-AI ecosystem.
    Current date/time: #{now} UTC
    Complete the task given to you using the tools available.

    PROTOCOL (mandatory, enforced by the runtime):
      0. PLAN FIRST: Before taking any other action, you MUST call:
             plan(steps: ["step 1", "step 2", ...], rationale: "brief explanation")
         List every step you intend to take — including which URLs to fetch, which tools
         to use, and what the final answer will cover. The runtime will approve or reject.
         If rejected, revise and resubmit. Only after approval may you proceed.
         MID-EXECUTION REPLAN: If you discover during execution that the plan is
         impossible or must change significantly (e.g. a URL is down, a tool fails
         unexpectedly, findings contradict your assumptions), call plan(...) again
         with the updated steps. The runtime re-approves before you continue.
         Do NOT replan for minor deviations — only when the overall approach must change.
      1. EXECUTE: Carry out your plan step by step using the available tools.
         - For any URL in the task: call web_fetch first. This is deterministic and free.
         - For time-sensitive or live data you cannot know from training (current events, prices, versions): call web_search (EXPENSIVE — check rule 3 before using).
         - Compile all gathered information into a coherent final answer.
      2. When finished, you MUST call:
             signal(status: "JOB_DONE", result: <final answer in Markdown>)
      3. If blocked by an error you cannot proceed past, you MUST call:
             signal(status: "BLOCKED", reason: <verbatim error message>)
      4. After calling signal, do not call any other tool. The runtime terminates you.

    Not calling signal means your work is lost. Returning plain text instead of
    a tool call as your final action is a protocol violation — the runtime
    will nudge you to call signal, and then abort with BLOCKED if you refuse.

    CRITICAL RULES:
      1. Language: the user's language is "#{lang}" (ISO 639-1). Every piece of
         user-facing output you produce — including the signal(result=...) text,
         signal(reason=...) text, and any tool arguments that will be echoed to
         the user — MUST be written in "#{lang}". Do not switch languages.
      2. Tool calls: ALWAYS via the tool-calling mechanism. Plain text that mimics tool calls (e.g. `[used: bash(...)]`) is FORBIDDEN.
      3. `web_search` is EXPENSIVE — the default is you do NOT need it.
        Before planning a search, ask: "Can I answer this from training data?" If yes, skip it.
        - NEVER for: translation, summarisation, writing, coding help, science, history, math, geography, astronomy, or any well-known stable concept.
        - Use ONLY for: breaking news, sports scores, stock/crypto prices, weather, current service status, software release versions, or anything that changes frequently and you genuinely do not know.
    """
  end

  # ─── Public API ────────────────────────────────────────────────────────────

  @doc """
  Start a fresh worker for a job.
  `ctx` MUST contain: user_id, session_id, worker_id, job_id, task, agent_pid (optional).
  Returns {:ok, {:signal, status, payload}} | {:error, reason}.
  """
  @spec run(String.t(), map()) ::
          {:ok, {:signal, String.t(), String.t()}} | {:error, term()}
  def run(task, context) do
    model = AgentSettings.worker_model()
    tools = ToolRegistry.all_definitions()
    language = Map.get(context, :language, "en")

    messages = [
      %{role: "system", content: build_system_prompt(language)},
      %{role: "user",   content: task}
    ]

    ctx =
      context
      |> Map.put(:worker_pid, self())
      |> Map.put(:task, task)
      |> Map.put_new(:rolling_summary, nil)
      |> Map.put_new(:language, language)
      |> Map.put_new(:violation_counts, %{})

    worker_id = Map.get(ctx, :worker_id, "unknown")
    job_id    = Map.get(ctx, :job_id)

    if is_nil(job_id) do
      Logger.error("[Worker] missing :job_id in ctx — refusing to run")
      {:error, :missing_job_id}
    else
      Logger.info("[Worker] starting model=#{model} job=#{job_id} worker=#{worker_id}")
      try do
        loop(messages, tools, model, ctx)
      rescue
        e ->
          lang = Map.get(context, :language, "en")
          msg  = Dmhai.I18n.t("internal_error", lang)
          Logger.error("[Worker] unhandled exception job=#{job_id}: #{Exception.message(e)}")
          WorkerStatus.append(job_id, worker_id, "final", msg, "BLOCKED")
          {:error, :internal_exception}
      end
    end
  end

  # ─── Private ───────────────────────────────────────────────────────────────

  defp loop(messages, tools, model, ctx) do
    {messages, ctx} = drain_subtask_results(messages, ctx)
    {messages, ctx} = maybe_compact_worker_messages(messages, ctx)

    iter     = Map.get(ctx, :iter, 0)
    max_iter = AgentSettings.worker_max_iter()

    if iter >= max_iter do
      Logger.warning("[Worker] max iterations (#{max_iter}) reached — forcing BLOCKED")
      lang = Map.get(ctx, :language, "en")
      emit_synthetic_final(ctx, "BLOCKED", Dmhai.I18n.t("max_iter_reached", lang, %{max: max_iter}))
      {:error, :max_iter_without_signal}
    else
      worker_id = Map.get(ctx, :worker_id, "unknown")
      job_id    = Map.get(ctx, :job_id)
      description = Map.get(ctx, :description, "")

      on_tokens = fn rx, tx ->
        TokenTracker.add_worker(ctx.session_id, ctx.user_id, worker_id, description, rx, tx)
      end

      Dmhai.SysLog.log("[WORKER] iter=#{iter} id=#{worker_id} job=#{job_id} msgs=#{length(messages)}\n  #{log_worker_messages(messages)}")

      # Inject rolling summary as a transient prefix — not stored in messages.
      effective_messages = inject_rolling_summary(messages, ctx)

      case LLM.call(model, effective_messages, tools: tools, on_tokens: on_tokens) do
        {:ok, {:tool_calls, calls}} ->
          handle_tool_calls(calls, messages, tools, model, ctx, iter)

        {:ok, text} when is_binary(text) and text != "" ->
          handle_text_response(text, messages, tools, model, ctx)

        {:ok, ""} ->
          Logger.warning("[Worker] empty response — forcing BLOCKED")
          lang = Map.get(ctx, :language, "en")
          emit_synthetic_final(ctx, "BLOCKED", Dmhai.I18n.t("llm_empty_response", lang))
          {:error, :empty_response}

        {:error, reason} ->
          Logger.error("[Worker] LLM error: #{inspect(reason)}")
          Dmhai.SysLog.log("[WORKER] id=#{worker_id} iter=#{iter} → ERROR: #{inspect(reason)}")
          lang = Map.get(ctx, :language, "en")
          emit_synthetic_final(ctx, "BLOCKED", Dmhai.I18n.t("llm_error", lang, %{reason: inspect(reason)}))
          {:error, inspect(reason)}
      end
    end
  end

  # ── tool_calls branch ─────────────────────────────────────────────────────

  defp handle_tool_calls(calls, messages, tools, model, ctx, iter) do
    worker_id = Map.get(ctx, :worker_id, "unknown")
    job_id    = Map.get(ctx, :job_id)

    call_names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
    Logger.info("[Worker] executing #{length(calls)} tool(s) iter=#{iter}: #{call_names}")
    Dmhai.SysLog.log("[WORKER] id=#{worker_id} iter=#{iter} → tool_calls=[#{call_names}]")

    case Police.check_tool_calls(calls, messages, ctx) do
      {:rejected, reason} ->
        handle_rejection(ctx, messages, tools, model, reason, nil)

      :ok ->
        # Write one worker_status row per pending tool call (BEFORE execution)
        Enum.each(calls, fn call ->
          name = get_in(call, ["function", "name"]) || ""
          args = get_in(call, ["function", "arguments"]) || %{}
          args_preview = Jason.encode!(args) |> String.slice(0, 600)
          WorkerStatus.append(job_id, worker_id, "tool_call", "#{name}(#{args_preview})")
        end)

        assistant_msg = %{role: "assistant", content: "", tool_calls: calls}

        {tool_result_msgs, signal_result} = execute_tools(calls, ctx)

        new_messages = messages ++ [assistant_msg] ++ tool_result_msgs

        # Only reset rejection counter when real work succeeds — not on plan-only calls
        # (replanning after a rejection is not progress and must not reset the guard).
        only_plan? = Enum.all?(calls, fn c -> get_in(c, ["function", "name"]) == "plan" end)
        new_consec = if only_plan?, do: Map.get(ctx, :consecutive_rejections, 0), else: 0

        new_ctx =
          ctx
          |> Map.put(:iter, iter + 1)
          |> Map.put(:consecutive_rejections, new_consec)

        case signal_result do
          {:terminate, status, payload} ->
            Logger.info("[Worker] signal received status=#{status} — exiting loop")
            {:ok, {:signal, status, payload}}

          nil ->
            loop(new_messages, tools, model, new_ctx)
        end
    end
  end

  # Execute each tool call sequentially. Returns {tool_result_messages, signal_or_nil}.
  # If the batch contains a `signal` call, capture its status/payload and return
  # {:terminate, status, payload} so the loop can exit cleanly.
  defp execute_tools(calls, ctx) do
    worker_id = Map.get(ctx, :worker_id, "unknown")
    job_id    = Map.get(ctx, :job_id)

    Enum.reduce(calls, {[], nil}, fn call, {acc_msgs, signal_acc} ->
      name         = get_in(call, ["function", "name"]) || ""
      args         = get_in(call, ["function", "arguments"]) || %{}
      tool_call_id = call["id"] || ""

      args_str = Jason.encode!(args) |> String.slice(0, 200)
      Dmhai.SysLog.log("[WORKER] id=#{worker_id} tool=#{name} args=#{args_str}")

      exec_result = ToolRegistry.execute(name, args, ctx)

      content =
        case exec_result do
          {:ok, result}    -> maybe_summarize_result(format_tool_result(result))
          {:error, reason} -> "Error: #{reason}"
        end

      WorkerStatus.append(job_id, worker_id, "tool_result", "#{name} → #{String.slice(content, 0, 300)}")

      # Only treat `signal` as terminal if the tool actually SUCCEEDED.
      # A failed signal call (bad args) is a normal tool error — let the
      # model see the error and retry with correct args.
      new_signal =
        if name == "signal" and match?({:ok, _}, exec_result) do
          status  = String.upcase(to_string(args["status"] || ""))
          payload = args["result"] || args["reason"] || ""
          {:terminate, status, payload}
        else
          signal_acc
        end

      tool_msg = %{role: "tool", content: content, tool_call_id: tool_call_id}
      {acc_msgs ++ [tool_msg], new_signal}
    end)
  end

  # ── text-response branch ──────────────────────────────────────────────────

  defp handle_text_response(text, messages, tools, model, ctx) do
    worker_id = Map.get(ctx, :worker_id, "unknown")
    iter = Map.get(ctx, :iter, 0)
    Dmhai.SysLog.log("[WORKER] id=#{worker_id} iter=#{iter} → text(#{String.length(text)} chars): #{String.slice(text, 0, 200)}")

    case Police.check_text(text, ctx) do
      {:rejected, reason} ->
        handle_rejection(ctx, messages, tools, model, reason, text)

      :ok ->
        # Text WITHOUT calling signal = protocol violation. Nudge, then fail hard.
        consec = Map.get(ctx, :consecutive_rejections, 0) + 1

        if consec >= @max_consecutive_rejections do
          Logger.error("[Worker] refused to call signal after #{consec} nudges — forcing BLOCKED")
          lang = Map.get(ctx, :language, "en")
          reason = Dmhai.I18n.t("worker_refused_signal", lang, %{
            count: consec,
            text: String.slice(text, 0, 800)
          })
          emit_synthetic_final(ctx, "BLOCKED", reason)
          {:error, :no_signal_after_nudges}
        else
          nudge = %{role: "user", content: protocol_nudge_msg()}
          assistant_msg = %{role: "assistant", content: text}
          new_ctx = Map.put(ctx, :consecutive_rejections, consec)
          loop(messages ++ [assistant_msg, nudge], tools, model, new_ctx)
        end
    end
  end

  defp protocol_nudge_msg do
    "PROTOCOL VIOLATION: You returned plain text instead of calling signal. " <>
      "End your work by calling signal(status: \"JOB_DONE\", result: <answer>) " <>
      "or signal(status: \"BLOCKED\", reason: <error>). Call signal now — do not repeat your text."
  end

  # Shared rejection handler: inject Police's rejection message + increment counters.
  # Two independent kill switches:
  #   1. consecutive_rejections — fires if model keeps violating with NO recovery between.
  #   2. violation_counts (per type) — fires if total violations of the same type reach
  #      the threshold regardless of any successful tool calls in between.
  defp handle_rejection(ctx, messages, tools, model, reason, last_assistant_text) do
    consec = Map.get(ctx, :consecutive_rejections, 0) + 1

    violation_type = reason |> String.split(":", parts: 2) |> hd() |> String.trim()
    violation_counts = Map.get(ctx, :violation_counts, %{})
    type_count = Map.get(violation_counts, violation_type, 0) + 1
    new_violation_counts = Map.put(violation_counts, violation_type, type_count)

    cond do
      type_count >= @max_consecutive_rejections ->
        Logger.error("[Worker] Police: '#{violation_type}' hit #{type_count} total violations — forcing BLOCKED")
        lang = Map.get(ctx, :language, "en")
        localized = Dmhai.I18n.t("policy_violation", lang, %{reason: reason})
        emit_synthetic_final(ctx, "BLOCKED", localized)
        {:error, "Repeated policy violation (#{type_count}×): #{reason}"}

      consec >= @max_consecutive_rejections ->
        Logger.error("[Worker] Police: #{consec} consecutive rejections (#{reason}) — forcing BLOCKED")
        lang = Map.get(ctx, :language, "en")
        localized = Dmhai.I18n.t("policy_violation", lang, %{reason: reason})
        emit_synthetic_final(ctx, "BLOCKED", localized)
        {:error, "Repeated policy violation: #{reason}"}

      true ->
        rejection_msg = %{role: "user", content: Police.rejection_msg(reason)}

        extra =
          if last_assistant_text do
            [%{role: "assistant", content: last_assistant_text}]
          else
            []
          end

        new_ctx =
          ctx
          |> Map.put(:consecutive_rejections, consec)
          |> Map.put(:violation_counts, new_violation_counts)

        loop(messages ++ extra ++ [rejection_msg], tools, model, new_ctx)
    end
  end

  # ── synthetic final ──────────────────────────────────────────────────────

  # Used when the runtime needs to force a BLOCKED/JOB_DONE row on the worker's
  # behalf (model refused signal, LLM error, iter cap hit).
  defp emit_synthetic_final(ctx, status, payload) do
    job_id    = Map.get(ctx, :job_id)
    worker_id = Map.get(ctx, :worker_id, "unknown")

    if job_id do
      WorkerStatus.append(job_id, worker_id, "final", payload, status)
    else
      Logger.error("[Worker] emit_synthetic_final called without job_id")
    end
  end

  # ─── Context compaction ────────────────────────────────────────────────────

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

      # Only DROP the old messages if the summariser successfully folded them
      # into the rolling summary. On failure we keep the old list in place so
      # no information is silently lost — compaction will retry next iteration.
      case update_rolling_summary(old, Map.get(ctx, :rolling_summary)) do
        {:ok, new_summary} ->
          new_messages = [system_msg] ++ stub_tool_results(middle) ++ recent
          new_ctx      = Map.put(ctx, :rolling_summary, new_summary)
          {new_messages, new_ctx}

        :failed ->
          Logger.warning("[Worker] compaction failed — keeping full message list (no context loss)")
          {messages, ctx}
      end
    end
  end

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

  # Returns {:ok, new_summary} on success or :failed if every retry of the
  # compactor LLM came back empty/errored. The caller must NOT drop the
  # spillover messages on :failed — that would silently lose context.
  defp update_rolling_summary([], current_summary), do: {:ok, current_summary}

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
        {:ok, new_summary}

      other ->
        Logger.warning("[Worker] rolling summary update failed: #{inspect(other)}")
        :failed
    end
  end

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

  # ─── Subtask result draining ─────────────────────────────────────────────

  # spawn_task delivers async bash output via {:subtask_result, output}.
  # We drain non-blockingly at the top of each loop and append as user messages.
  defp drain_subtask_results(messages, ctx) do
    collect_results(messages, ctx, [])
  end

  defp collect_results(messages, ctx, results) do
    receive do
      {:subtask_result, output} ->
        collect_results(messages, ctx, results ++ [maybe_summarize_result(output)])
    after 0 ->
      if results == [] do
        {messages, ctx}
      else
        extra = Enum.map(results, fn r ->
          %{role: "user", content: "[Scheduled task result]\n#{r}"}
        end)
        {messages ++ extra, ctx}
      end
    end
  end

  defp format_tool_result(result) when is_binary(result), do: result

  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: Jason.encode!(result, pretty: true)

  defp format_tool_result(result), do: inspect(result)

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
