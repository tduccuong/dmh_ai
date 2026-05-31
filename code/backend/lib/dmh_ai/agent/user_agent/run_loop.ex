# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent.RunLoop do
  @moduledoc """
  The Assistant chain loop: one chain = sequence of turns (LLM call +
  tool execution) until the model emits user-facing text with no tool
  calls. Returns `{:chain_done, watermark_ts}` so the shell knows
  whether to auto-resume (mid-chain user messages bumped the
  watermark).

  Pure function — receives the working ctx from the shell. Calls into
  `ToolExecution`, `CircuitBreaker`, `SessionIO`, `ProfileResolution`,
  `ContextBuilders`, and `StreamCollectors`.
  """

  alias DmhAi.Agent.{AgentSettings, LLM, StreamBuffer, ThinkingBuffer}

  alias DmhAi.Agent.UserAgent.{
    CircuitBreaker,
    ContextBuilders,
    ProfileResolution,
    SessionIO,
    StreamCollectors,
    ToolExecution
  }

  @doc """
  Chain loop entry point. Enforces the per-chain turn cap and
  cooperative cancellation, splices mid-chain user messages, and
  rotates stale tool results.
  Returns `{:chain_done, watermark_ts}`.
  """
  def session_chain_loop(messages, model, ctx, turn) do
    max_turns = AgentSettings.max_assistant_turns_per_chain()

    messages = SessionIO.splice_mid_chain_user_msgs(messages, ctx)
    messages = SessionIO.flush_stale_tool_results(messages, turn)

    cond do
      ContextBuilders.session_cancelled?(ctx) ->
        _ = StreamBuffer.clear(ctx.session_id, ctx.user_id)
        _ = ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
        progress_ctx = %{session_id: ctx.session_id, user_id: ctx.user_id}
        {:ok, _} = DmhAi.Agent.SessionProgress.append(
          progress_ctx, "chain_aborted", "Stopped by user.")
        {:chain_done, SessionIO.max_user_ts_in_messages(messages)}

      turn >= max_turns ->
        msg = DmhAi.I18n.t("turn_cap_reached", "en", %{max: max_turns})
        cap_msg = %{role: "assistant", content: msg}
        {:ok, _} = SessionIO.append_session_message(ctx.session_id, ctx.user_id, cap_msg)
        ContextBuilders.emit_chain_end(ctx, "turn_cap")
        {:chain_done, SessionIO.max_user_ts_in_messages(messages)}

      true ->
        do_one_turn(messages, model, ctx, turn)
    end
  end

  defp do_one_turn(messages, model, ctx, turn) do
    active_profiles = DmhAi.Agent.SessionContext.active_profiles(ctx.session_id)
    ctx = Map.put(ctx, :active_profiles, active_profiles)
    tools = DmhAi.Tools.Registry.all_definitions(ctx.user_id, ctx.session_id, active_profiles)

    # Pin the active-profile catalog into the outgoing context (NOT
    # persisted). The manifest the model needs to compose IR survives
    # the rolling tool-result flush this way — it's rebuilt every turn
    # from active_profiles, so it's authoritative and vanishes when the
    # chain ends (active set resets). See architecture.md §Tool profiles.
    outgoing = ProfileResolution.inject_active_catalog(messages, active_profiles, ctx)

    trace = %{
      origin: "assistant",
      path: "UserAgent.session_chain",
      role: "AssistantSession",
      phase: "turn#{turn}",
      session_id: ctx.session_id,
      user_id: ctx.user_id,
      tier: :master
    }

    collector = StreamCollectors.spawn_assistant_stream_collector(ctx.session_id, ctx.user_id)
    llm_options = %{num_predict: AgentSettings.llm_num_predict_assistant()}
    result = LLM.stream(model, outgoing, collector,
                        tools: tools, options: llm_options,
                        trace: trace)
    StreamCollectors.stop_stream_collector(collector)

    case result do
      {:ok, {:tool_calls, calls}} ->
        handle_tool_calls(calls, messages, model, ctx, turn)

      {:ok, text} when is_binary(text) ->
        handle_text_turn(text, messages, model, ctx, turn)

      {:error, reason} ->
        handle_error(reason, messages, ctx)
    end
  end

  defp handle_tool_calls(calls, messages, model, ctx, turn) do
    call_names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
    DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} tool_calls=[#{call_names}]")

    raw_narration  = StreamBuffer.read(ctx.session_id, ctx.user_id)
    clean_narration = DmhAi.Agent.TextSanitizer.strip_tool_bookkeeping(raw_narration)
    StreamBuffer.clear(ctx.session_id, ctx.user_id)
    ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

    may_emit_form? = Enum.any?(calls, fn c ->
      (get_in(c, ["function", "name"]) || "") in ~w(request_input connect_mcp)
    end)

    if String.trim(clean_narration) != "" and not may_emit_form? do
      DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} narration(#{String.length(clean_narration)} chars) persisted")
      narration_msg = %{role: "assistant", content: clean_narration}
      {:ok, _} = SessionIO.append_session_message(ctx.session_id, ctx.user_id, narration_msg)
    end

    {tool_result_msgs_raw, tagged_calls, exec_results, ctx} = ToolExecution.execute_tools(calls, messages, ctx)
    assistant_msg = %{role: "assistant", content: clean_narration, tool_calls: tagged_calls}

    {ctx, tool_result_msgs} = CircuitBreaker.bump_nudge_counters(ctx, tool_result_msgs_raw)
    tool_result_msgs = Enum.map(tool_result_msgs, &Map.put(&1, :emit_turn, turn))
    form = if may_emit_form?, do: ContextBuilders.extract_form_from_results(exec_results), else: nil

    cond do
      form != nil ->
        content =
          case String.trim(clean_narration) do
            "" -> ContextBuilders.fallback_content_for_form(form)
            s  -> s
          end

        msg = %{role: "assistant", content: content, form: form}
        {:ok, _} = SessionIO.append_session_message(ctx.session_id, ctx.user_id, msg)
        DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} form persisted (kind=#{form["kind"] || "request_input"} token=#{form["token"] || form[:token]})")
        ContextBuilders.emit_chain_end(ctx, "form")
        {:chain_done, SessionIO.max_user_ts_in_messages(messages)}

      true ->
        case CircuitBreaker.maybe_abort_on_model_behavior_issue(ctx, model) do
          :continue ->
            new_messages = messages ++ [assistant_msg] ++ tool_result_msgs
            session_chain_loop(new_messages, model, ctx, turn + 1)

          :aborted ->
            ContextBuilders.emit_chain_end(ctx, "aborted")
            {:chain_done, SessionIO.max_user_ts_in_messages(messages)}
        end
    end
  end

  defp handle_text_turn(text, messages, model, ctx, turn) do
    case DmhAi.Agent.Police.check_assistant_text(text) do
      {:rejected, tagged_or_reason} ->
        {issue_atom, reason} =
          case tagged_or_reason do
            {atom, text_reason} when is_atom(atom) -> {atom, text_reason}
            plain when is_binary(plain)            -> {:assistant_text, plain}
          end

        DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} rejected text='#{String.slice(text, 0, 80)}' — nudging for retry")
        StreamBuffer.clear(ctx.session_id, ctx.user_id)
        ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
        ctx = CircuitBreaker.record_non_tool_issue(ctx, issue_atom)

        new_messages =
          messages ++ [
            %{role: "assistant", content: text},
            %{role: "user",      content: CircuitBreaker.wrap_runtime_correction(reason)}
          ]

        case CircuitBreaker.maybe_abort_on_model_behavior_issue(ctx, model) do
          :continue ->
            session_chain_loop(new_messages, model, ctx, turn + 1)

          :aborted ->
            ContextBuilders.emit_chain_end(ctx, "aborted")
            {:chain_done, SessionIO.max_user_ts_in_messages(messages)}
        end

      :ok ->
        fresh_paths = Map.get(ctx, :fresh_attachment_paths, [])

        case DmhAi.Agent.Police.check_fresh_attachments_read(fresh_paths, messages) do
          {:rejected, tagged_or_reason} ->
            {issue_atom, reason} =
              case tagged_or_reason do
                {atom, r} when is_atom(atom) -> {atom, r}
                plain when is_binary(plain)  -> {:fresh_attachments_unread, plain}
              end

            DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} rejected fresh-attachment-miss — nudging for retry")
            StreamBuffer.clear(ctx.session_id, ctx.user_id)
            ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
            ctx = CircuitBreaker.record_non_tool_issue(ctx, issue_atom)

            new_messages =
              messages ++ [
                %{role: "assistant", content: text},
                %{role: "user",      content: CircuitBreaker.wrap_runtime_correction(reason)}
              ]

            case CircuitBreaker.maybe_abort_on_model_behavior_issue(ctx, model) do
              :continue ->
                session_chain_loop(new_messages, model, ctx, turn + 1)

              :aborted ->
                ContextBuilders.emit_chain_end(ctx, "aborted")
                {:chain_done, SessionIO.max_user_ts_in_messages(messages)}
            end

          :ok ->
            case DmhAi.Agent.Police.check_no_phantom_outcome(Map.get(ctx, :outcome_attempts, 0), Map.get(ctx, :outcome_failures, 0)) do
              {:rejected, {issue_atom, reason}} ->
                DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} rejected phantom_outcome — nudging for retry")
                StreamBuffer.clear(ctx.session_id, ctx.user_id)
                ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
                ctx = CircuitBreaker.record_non_tool_issue(ctx, issue_atom)

                new_messages =
                  messages ++ [
                    %{role: "assistant", content: text},
                    %{role: "user",      content: CircuitBreaker.wrap_runtime_correction(reason)}
                  ]

                case CircuitBreaker.maybe_abort_on_model_behavior_issue(ctx, model) do
                  :continue ->
                    session_chain_loop(new_messages, model, ctx, turn + 1)

                  :aborted ->
                    ContextBuilders.emit_chain_end(ctx, "aborted")
                    {:chain_done, SessionIO.max_user_ts_in_messages(messages)}
                end

              :ok ->
                clean_text = DmhAi.Agent.TextSanitizer.strip_tool_bookkeeping(text)
                DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} text(#{String.length(clean_text)} chars)")
                thinking_text = ThinkingBuffer.read(ctx.session_id, ctx.user_id)
                base_msg = %{role: "assistant", content: clean_text}
                base_msg = if thinking_text != "",
                              do: Map.put(base_msg, :thinking, thinking_text),
                              else: base_msg
                {:ok, _assistant_ts} =
                  SessionIO.append_session_message(ctx.session_id, ctx.user_id, base_msg)
                StreamBuffer.clear(ctx.session_id, ctx.user_id)
                ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

                ContextBuilders.emit_chain_end(ctx, "final_text")
                {:chain_done, SessionIO.max_user_ts_in_messages(messages)}
            end
        end
    end
  end

  defp handle_error(reason, messages, ctx) do
    DmhAi.SysLog.log("[ASSISTANT] ERROR: #{inspect(reason)}")
    StreamBuffer.clear(ctx.session_id, ctx.user_id)
    ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

    err_msg = %{
      role: "assistant",
      content: DmhAi.I18n.t("llm_error", "en", %{reason: inspect(reason)})
    }
    {:ok, _} = SessionIO.append_session_message(ctx.session_id, ctx.user_id, err_msg)
    ContextBuilders.emit_chain_end(ctx, "error")
    {:chain_done, SessionIO.max_user_ts_in_messages(messages)}
  end
end
