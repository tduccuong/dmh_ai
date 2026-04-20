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

  PROTOCOL contract: every job MUST end with a call to
  `job_signal(status, reason?)`. The job_signal tool writes a
  `kind='final'` row to worker_status; the runtime picks that up as
  the job's terminal state.

  Loop:
    1. Drain any {:subtask_result, output} messages from the mailbox
       (from async spawn_task calls). Append as user messages.
    2. Apply rolling-summary compaction if messages exceed system + N + M + 5.
    3. Compute effective_tools: plan-only until first plan is approved, then
       adaptive selection (media tools gated on context signals).
    4. Build a per-turn system prompt matching the current phase (plan vs
       execution) and the active tool set. Inject it into effective_messages
       alongside the rolling summary — stored messages[0] stays a placeholder.
    5. Call LLM with effective_messages and effective_tools.
    6. tool_calls → write worker_status rows (tool_call + tool_result),
       execute tools, then dispatch on any signal in the batch:
       - job_signal           → exit loop (terminal).
       - step_signal STEP_DONE → advance current_step, loop.
       - step_signal STEP_BLOCKED → retry or force BLOCKED after max retries.
       - step_signal PLAN_REVISE → reset plan_approved, inject message, loop.
       - no signal            → loop.
    7. Text response → Police nudges the model to call job_signal; after
       @max_consecutive_rejections the runtime synthesises BLOCKED.

  The ctx map MUST contain :job_id. All worker_status rows are keyed by it.
  """

  alias Dmhai.Agent.{AgentSettings, LLM, LogTrace, Police, Prompts, TokenTracker, WorkerStatus}
  alias Dmhai.Tools.Registry, as: ToolRegistry
  require Logger

  # Max consecutive Police rejections before giving up.
  @max_consecutive_rejections 3

  # Max consecutive plan tool errors before giving up. Prevents runaway loops
  # when a model repeatedly submits malformed plans that the tool rejects — these
  # errors are not Police rejections so the normal kill-switch never fires.
  @max_plan_errors 3

  # Consecutive execution-tool failures trigger a nudge (threshold from AgentSettings).
  # A second streak after the nudge requests a full worker restart.

  # Summarise tool results larger than this before injecting into history.
  @summarize_threshold Application.compile_env(:dmhai, [:worker, :summarize_threshold], 5_000)

  # Number of recent messages scanned each turn to decide which optional
  # (media/document) tools to include. Larger window = more context at the cost
  # of a slightly larger scan string. Related: select_tools/3, build_scan_text/2.
  @tool_scan_window 5

  defp compactor_model, do: AgentSettings.compactor_model()

  # Public wrapper used only by the i18n test to verify language interpolation.
  # Production code injects per-turn prompts via build_turn_prompt/4.
  @doc false
  def build_system_prompt(language \\ "en") do
    now = DateTime.utc_now() |> DateTime.to_iso8601() |> String.slice(0, 16)
    Prompts.execution_phase_prompt(language || "en", now, ToolRegistry.all_definitions(), %{})
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

    # Stored messages[0] is a stable placeholder — build_turn_prompt/4 injects
    # the real per-turn prompt into effective_messages before each LLM call,
    # so this content never reaches the model. It is kept for compaction
    # consistency: the system message position is always slot 0.
    messages = [
      %{role: "system", content: "[worker — per-turn prompt injected each iteration]"},
      %{role: "user",   content: task}
    ]

    ctx =
      context
      |> Map.put(:worker_pid, self())
      |> Map.put(:task, task)
      |> Map.put_new(:rolling_summary, nil)
      |> Map.put_new(:language, language)
      |> Map.put_new(:violation_counts, %{})
      |> Map.put_new(:error_msgs, MapSet.new())
      |> Map.put_new(:plan_approved, false)
      |> Map.put_new(:step_retries, %{})

    worker_id = Map.get(ctx, :worker_id, "unknown")
    job_id    = Map.get(ctx, :job_id)

    if is_nil(job_id) do
      Logger.error("[Worker] missing :job_id in ctx — refusing to run")
      {:error, :missing_job_id}
    else
      Logger.info("[Worker] starting model=#{model} job=#{job_id} worker=#{worker_id}")
      LogTrace.init_log(ctx)
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
        TokenTracker.add_worker(ctx.session_id, ctx.user_id, worker_id, job_id, description, rx, tx)
      end

      Dmhai.SysLog.log("[WORKER] iter=#{iter} id=#{worker_id} job=#{job_id} msgs=#{length(messages)}\n  #{log_worker_messages(messages)}")

      # Before the first plan is approved, offer only the plan tool so the model
      # cannot skip planning. Once approved, adaptively select tools each turn
      # by scanning recent context — optional media tools are only included when
      # signals for them appear in the task or recent messages.
      effective_tools =
        if Map.get(ctx, :plan_approved, false) do
          select_tools(tools, messages, ctx)
        else
          Enum.filter(tools, fn t -> (t[:name] || t["name"]) == "plan" end)
        end

      # Build a per-turn system prompt that matches the current phase (plan vs
      # execution) and the active tool set. The stored messages[0] is a static
      # placeholder — only effective_messages gets the turn-specific prompt, so
      # compaction always sees a consistent history regardless of which turn we're on.
      lang        = Map.get(ctx, :language, "en")
      turn_prompt = build_turn_prompt(lang, effective_tools, ctx, tools)

      effective_messages =
        messages
        |> inject_rolling_summary(ctx)
        |> List.update_at(0, fn _ -> %{role: "system", content: turn_prompt} end)

      LogTrace.trace_call(ctx, iter, effective_messages, effective_tools)
      result = LLM.call(model, effective_messages, tools: effective_tools, on_tokens: on_tokens)
      LogTrace.trace_response(ctx, iter, result)

      case result do
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

        {tool_result_msgs, signal_result, new_err_msgs} = execute_tools(calls, ctx)

        new_messages = messages ++ [assistant_msg] ++ tool_result_msgs

        # Only reset rejection counter when real work succeeds — not on plan-only calls
        # (replanning after a rejection is not progress and must not reset the guard).
        only_plan? = Enum.all?(calls, fn c -> get_in(c, ["function", "name"]) == "plan" end)
        new_consec = if only_plan?, do: Map.get(ctx, :consecutive_rejections, 0), else: 0

        merged_err_msgs = MapSet.union(Map.get(ctx, :error_msgs, MapSet.new()), new_err_msgs)

        # Plan approved when a plan call succeeded (result not in error set).
        # Once true it stays true — mid-execution replans don't reset it.
        zipped = Enum.zip(calls, tool_result_msgs)

        plan_just_approved? =
          Enum.any?(zipped, fn {call, result_msg} ->
            get_in(call, ["function", "name"]) == "plan" and
              not MapSet.member?(new_err_msgs, result_msg)
          end)

        # Track consecutive plan-tool errors to kill runaway loops. Police repeat
        # detection can't catch these because compaction wipes old tool_calls from
        # messages, and plan errors are not Police rejections so consecutive_rejections
        # never fires. Reset to 0 on first approval.
        plan_error_count =
          cond do
            plan_just_approved? -> 0
            only_plan? and not plan_just_approved? ->
              Map.get(ctx, :plan_error_count, 0) + 1
            true ->
              Map.get(ctx, :plan_error_count, 0)
          end

        if plan_error_count >= @max_plan_errors do
          Logger.error("[Worker] plan failed #{plan_error_count} times in a row — forcing BLOCKED")
          {:ok, {:signal, "JOB_BLOCKED",
            "Plan submission failed #{plan_error_count} consecutive times. " <>
            "The model could not produce a valid plan."}}
        else

        # On ANY plan approval (first or mid-execution replan), extract the new steps
        # and reset current_step to 1. Both plan() replans and step_signal(PLAN_REVISE)
        # flow through here — the model must always re-submit via plan().
        new_plan_steps =
          if plan_just_approved? do
            case Enum.find(zipped, fn {call, result_msg} ->
               get_in(call, ["function", "name"]) == "plan" and
                 not MapSet.member?(new_err_msgs, result_msg)
             end) do
              {plan_call, _} ->
                raw = get_in(plan_call, ["function", "arguments", "steps"]) || []
                raw |> Enum.with_index(1) |> Enum.map(fn {s, id} ->
                  label = if is_map(s), do: s["step"] || "", else: to_string(s)
                  %{id: id, label: label}
                end)
              nil ->
                []
            end
          else
            Map.get(ctx, :plan_steps, [])
          end

        # Track consecutive iterations where every execution tool errored. Kills
        # loops where the model retries broken calls indefinitely (e.g. wrong param
        # name). Signal/plan calls are excluded — only run_script, web_search etc.
        # Reset on plan approval (fresh start) or when any exec tool succeeds.
        signal_names = MapSet.new(["plan", "job_signal", "step_signal"])
        exec_zipped  = Enum.reject(zipped, fn {c, _} ->
          MapSet.member?(signal_names, get_in(c, ["function", "name"]) || "")
        end)

        exec_error_streak =
          cond do
            plan_just_approved? -> 0
            exec_zipped == []   -> Map.get(ctx, :exec_error_streak, 0)
            Enum.all?(exec_zipped, fn {_, r} -> MapSet.member?(new_err_msgs, r) end) ->
              Map.get(ctx, :exec_error_streak, 0) + 1
            true -> 0
          end

        nudge_threshold = AgentSettings.exec_error_streak_nudge()
        nudge_sent      = Map.get(ctx, :exec_nudge_sent, false)

        cond do
          exec_error_streak >= nudge_threshold and not nudge_sent ->
            Logger.warning("[Worker] #{exec_error_streak} consecutive exec errors — nudging job=#{job_id}")
            nudge_msg = %{role: "user", content: exec_error_nudge_msg()}
            nudged_ctx =
              ctx
              |> Map.put(:iter, iter + 1)
              |> Map.put(:consecutive_rejections, new_consec)
              |> Map.put(:plan_error_count, plan_error_count)
              |> Map.put(:exec_error_streak, 0)
              |> Map.put(:exec_nudge_sent, true)
              |> Map.put(:error_msgs, merged_err_msgs)
              |> Map.put(:plan_steps, new_plan_steps)
            loop(new_messages ++ [nudge_msg], tools, model, nudged_ctx)

          exec_error_streak >= nudge_threshold ->
            Logger.error("[Worker] exec errors persist after nudge — requesting restart job=#{job_id}")
            reason = "Worker failed #{exec_error_streak} consecutive times after warning."
            emit_synthetic_final(ctx, "JOB_RESTART", reason)
            {:ok, {:signal, "JOB_RESTART", reason}}

          true ->
            new_ctx =
              ctx
              |> Map.put(:iter, iter + 1)
              |> Map.put(:consecutive_rejections, new_consec)
              |> Map.put(:plan_error_count, plan_error_count)
              |> Map.put(:exec_error_streak, exec_error_streak)
              |> Map.put(:error_msgs, merged_err_msgs)
              |> then(fn c -> if plan_just_approved?, do: Map.put(c, :plan_approved, true), else: c end)
              |> Map.put(:plan_steps, new_plan_steps)
              |> then(fn c -> if plan_just_approved?, do: Map.put(c, :current_step, 1), else: c end)
              |> then(fn c -> if plan_just_approved?, do: Map.put(c, :step_retries, %{}), else: c end)

            case signal_result do
              {:terminate, status, payload} ->
                Logger.info("[Worker] job_signal received status=#{status} — exiting loop")
                {:ok, {:signal, status, payload}}

              {:step, "STEP_DONE", step_args} ->
                handle_step_done(step_args, new_messages, tools, model, new_ctx)

              {:step, "STEP_BLOCKED", step_args} ->
                handle_step_blocked(step_args, new_messages, tools, model, new_ctx)

              {:step, "PLAN_REVISE", step_args} ->
                handle_plan_revision(step_args, new_messages, tools, model, new_ctx)

              _ ->
                loop(new_messages, tools, model, new_ctx)
            end
        end  # cond exec_error_streak
        end  # plan_error_count guard
    end
  end

  # Execute each tool call sequentially.
  # Returns {tool_result_messages, signal_or_nil, error_msgs}.
  # signal_or_nil is one of:
  #   {:terminate, status, payload} — job_signal succeeded; loop exits.
  #   {:step, status, args}         — step_signal succeeded; loop dispatches.
  #   nil                           — no signal in this batch.
  # error_msgs is a MapSet of tool result message maps whose tool returned
  # {:error, _}. Stored in ctx so compaction keeps them verbatim rather than
  # stubbing — identified by Elixir value equality, no tool_call_id needed.
  defp execute_tools(calls, ctx) do
    worker_id = Map.get(ctx, :worker_id, "unknown")
    job_id    = Map.get(ctx, :job_id)

    Enum.reduce(calls, {[], nil, MapSet.new()}, fn call, {acc_msgs, signal_acc, err_msgs} ->
      name         = get_in(call, ["function", "name"]) || ""
      args         = get_in(call, ["function", "arguments"]) || %{}
      tool_call_id = call["id"] || ""

      args_encoded = Jason.encode!(args)
      args_str = if name == "plan", do: args_encoded, else: String.slice(args_encoded, 0, 200)
      Dmhai.SysLog.log("[WORKER] id=#{worker_id} tool=#{name} args=#{args_str}")

      exec_result = ToolRegistry.execute(name, args, ctx)

      content =
        case exec_result do
          {:ok, result}    -> maybe_summarize_result(format_tool_result(result))
          {:error, reason} -> "Error: #{reason}"
        end

      WorkerStatus.append(job_id, worker_id, "tool_result", "#{name} → #{String.slice(content, 0, 300)}")

      # Only treat signal tools as special if they actually SUCCEEDED.
      # A failed call is a normal tool error — model sees it and retries.
      new_signal =
        cond do
          name == "job_signal" and match?({:ok, _}, exec_result) ->
            status  = String.upcase(to_string(args["status"] || ""))
            payload = args["result"] || args["reason"] || ""
            {:terminate, status, payload}

          name == "step_signal" and match?({:ok, _}, exec_result) ->
            status = String.upcase(to_string(args["status"] || ""))
            {:step, status, args}

          true ->
            signal_acc
        end

      tool_msg = %{role: "tool", content: content, tool_call_id: tool_call_id}

      new_err_msgs =
        if match?({:error, _}, exec_result),
          do: MapSet.put(err_msgs, tool_msg),
          else: err_msgs

      {acc_msgs ++ [tool_msg], new_signal, new_err_msgs}
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
          nudge = %{role: "user", content: protocol_nudge_msg(ctx)}
          assistant_msg = %{role: "assistant", content: text}
          new_ctx = Map.put(ctx, :consecutive_rejections, consec)
          loop(messages ++ [assistant_msg, nudge], tools, model, new_ctx)
        end
    end
  end

  defp protocol_nudge_msg(ctx) do
    if Map.get(ctx, :plan_approved, false) do
      "PROTOCOL VIOLATION: You returned plain text instead of calling job_signal. " <>
        "End your work by calling job_signal(status: \"JOB_DONE\", result: \"...\") " <>
        "or job_signal(status: \"JOB_BLOCKED\", reason: \"...\"). Call job_signal now — do not repeat your text."
    else
      "PROTOCOL VIOLATION: You returned plain text instead of calling plan(). " <>
        "You must call plan(steps: [...], rationale: \"...\") to submit your plan. " <>
        "Call plan() now — do not repeat your text."
    end
  end

  defp exec_error_nudge_msg do
    "WARNING: You have failed #{AgentSettings.exec_error_streak_nudge()} consecutive tool calls in a row. " <>
      "Re-evaluate your entire approach — your current strategy is not working. " <>
      "Try a fundamentally different method. If you continue to fail, the job will be restarted."
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

  # ── step signal handlers ─────────────────────────────────────────────────

  # Advance to next step. The runtime's current_step is the source of truth —
  # the model's reported id is checked for logging but never drives advancement.
  # If model called STEP_DONE on the last step (should have called job_signal
  # directly per the prompt), nudge it to compile the final report.
  defp handle_step_done(step_args, messages, tools, model, ctx) do
    plan_steps   = Map.get(ctx, :plan_steps, [])
    current_step = Map.get(ctx, :current_step)
    reported_id  = parse_step_id(step_args["id"])
    last_step_id = if plan_steps != [], do: List.last(plan_steps).id, else: nil

    if reported_id != current_step do
      Logger.warning("[Worker] step_signal STEP_DONE reported id=#{reported_id}, corrected to current_step=#{current_step}")
    end

    if is_integer(last_step_id) and current_step == last_step_id do
      Logger.info("[Worker] step_signal(STEP_DONE) on last step #{current_step} — nudging to call job_signal with result")
      nudge = %{
        role: "user",
        content: "All steps are now complete. Compile your final deliverable and call " <>
                 "job_signal(status: \"JOB_DONE\", result: \"<your full report/answer>\") now. " <>
                 "Do not call step_signal again."
      }
      loop(messages ++ [nudge], tools, model, Map.put(ctx, :current_step, current_step + 1))
    else
      loop(messages, tools, model, Map.put(ctx, :current_step, current_step + 1))
    end
  end

  # Increment retry count for the blocked step. If retries are exhausted,
  # force BLOCKED. Otherwise inject a retry nudge and continue the loop.
  defp handle_step_blocked(step_args, messages, tools, model, ctx) do
    step_id    = parse_step_id(step_args["id"])
    reason     = step_args["reason"] || "no reason provided"
    max_retry  = AgentSettings.plan_step_max_retries()
    retries    = Map.get(ctx, :step_retries, %{})
    count      = Map.get(retries, step_id, 0) + 1

    if count >= max_retry do
      Logger.warning("[Worker] step #{step_id} blocked #{count} times — forcing BLOCKED")
      msg = "Step #{step_id} blocked after #{count} attempts: #{reason}"
      emit_synthetic_final(ctx, "BLOCKED", msg)
      {:error, :step_retries_exhausted}
    else
      Logger.info("[Worker] step #{step_id} blocked (attempt #{count}/#{max_retry}): #{reason}")
      retry_msg = %{
        role: "user",
        content: "Step #{step_id} is blocked: #{reason}. " <>
                 "Resolve the issue and retry, or call step_signal(PLAN_REVISE) if the plan must change."
      }
      new_ctx = Map.put(ctx, :step_retries, Map.put(retries, step_id, count))
      loop(messages ++ [retry_msg], tools, model, new_ctx)
    end
  end

  # Reset to plan phase so the model must re-submit a formal plan via plan().
  # Police step-count and content checks run on re-submission as usual.
  defp handle_plan_revision(step_args, messages, tools, model, ctx) do
    reason    = step_args["reason"] || "no reason provided"
    new_steps = step_args["new_steps"] || []

    Logger.info("[Worker] plan revision requested: #{reason}")

    new_ctx =
      ctx
      |> Map.put(:plan_approved, false)
      |> Map.put(:plan_steps, [])
      |> Map.put(:current_step, 1)
      |> Map.put(:step_retries, %{})

    steps_text =
      new_steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} -> "  #{i}. #{s}" end)

    revision_msg = %{
      role: "user",
      content: "Plan revision noted. Reason: #{reason}\n\n" <>
               "Proposed new plan:\n#{steps_text}\n\n" <>
               "Submit this as your revised plan via plan(steps: [...]) to get it approved before proceeding."
    }

    loop(messages ++ [revision_msg], tools, model, new_ctx)
  end

  # Step IDs are integers (1-based) in ctx, but the model sends them as JSON
  # strings in tool args. Parse safely — invalid input defaults to 0.
  defp parse_step_id(id) when is_integer(id), do: id
  defp parse_step_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> 0
    end
  end
  defp parse_step_id(_), do: 0

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

    # +5 slack: compaction result is 1+n+m messages, so 5 new messages can
    # accumulate before the next compaction — prevents per-iteration thrashing.
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
      error_msgs = Map.get(ctx, :error_msgs, MapSet.new())

      case update_rolling_summary(old, Map.get(ctx, :rolling_summary)) do
        {:ok, new_summary} ->
          new_messages = [system_msg] ++ stub_tool_results(middle, error_msgs) ++ recent
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

  defp stub_tool_results(messages, error_msgs) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      if role == "tool" and not MapSet.member?(error_msgs, msg) do
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

  # ─── Adaptive tool selection ──────────────────────────────────────────────

  # Scans the task brief and the last @tool_scan_window messages to decide which
  # optional tools to include. Media tools carry large token-cost definitions and
  # are rarely needed — only include them when the context contains explicit
  # signals (file extensions, keywords). All other tools are always included.
  defp select_tools(tools, messages, ctx) do
    scan = build_scan_text(messages, ctx)

    Enum.filter(tools, fn t ->
      case t[:name] || t["name"] do
        "plan"            -> false  # plan phase only; removed from execution to prevent gratuitous replanning
        "extract_content" -> Regex.match?(~r/\.(jpg|jpeg|png|gif|webp|bmp|mp4|mov|avi|mkv|webm)|image|photo|screenshot|video|attachment|workspace\//i, scan)
        "parse_document"  -> Regex.match?(~r/\.(pdf|docx|odt|pptx|epub)|document|parse_document/i, scan)
        _                -> true
      end
    end)
  end

  defp build_scan_text(messages, ctx) do
    recent =
      messages
      |> Enum.reject(fn m -> (m[:role] || m["role"]) == "system" end)
      |> Enum.take(-@tool_scan_window)
      |> Enum.map_join(" ", fn m -> to_string(m[:content] || m["content"] || "") end)

    to_string(Map.get(ctx, :task, "")) <> " " <> recent
  end

  # ─── Per-turn prompt ──────────────────────────────────────────────────────

  # Entry point: dispatches to the plan or execution prompt builder.
  # effective_tools  — the callable set for this turn (plan-only or adaptive subset).
  # all_tools        — the full ToolRegistry list, used in plan phase to enumerate
  #                    every tool the model may reference in its step labels even
  #                    though only `plan` is callable.
  # ctx.plan_approved — false = plan phase, true = execution phase.
  defp build_turn_prompt(lang, effective_tools, ctx, all_tools) do
    now   = DateTime.utc_now() |> DateTime.to_iso8601() |> String.slice(0, 16)
    phase = if Map.get(ctx, :plan_approved, false), do: :execute, else: :plan

    case phase do
      :plan    -> Prompts.plan_phase_prompt(lang, now, all_tools)
      :execute -> Prompts.execution_phase_prompt(lang, now, effective_tools, ctx)
    end
  end

  # Minimal planning-phase prompt.
  #
  # Why minimal: the model cannot call any execution tool yet, so detailed
  # execution rules waste tokens. We only need: task framing, terse step format,

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
