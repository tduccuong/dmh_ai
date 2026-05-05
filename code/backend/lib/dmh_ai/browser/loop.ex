# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Browser.Loop do
  @moduledoc """
  Phase 3 of #215 — observe→ask→act loop driving the sandbox-side
  browser daemon (`Browser.DaemonClient`) on behalf of `Tools.BrowserTask`.

  ## Loop shape

  ```
  navigate(start_url)
  loop:
    observation = extract_text + accessibility_snapshot
    screenshot  = step_<N>.png  (if browserScreenshotEnabled)
    decision    = browserAgentModel.ask(goal, constraints, observation, history)
    case decision.action of
      "complete" → return {:ok, completed}
      "abort"    → return {:ok, aborted}
      <command>  → daemon.dispatch ; append (decision, result) to history
    emit kind="browser_step" progress row
    halt if turn ≥ browserMaxTurnsPerTask OR elapsed ≥ browserMaxRuntimeMs
  ```

  ## Halt conditions (any one)

    1. `action: "complete"` — model declares the goal achieved.
    2. `action: "abort"` — model gives up with a reason.
    3. Turn count ≥ `browserMaxTurnsPerTask` (default 50).
    4. Wall clock ≥ `browserMaxRuntimeMs` (default 30 min).
    5. Daemon error containing `"Cloudflare"`/`"captcha"`/login-wall
       heuristics → returns `{:ok, %{status: "auth_handoff_required"}}`
       (proper noVNC handoff lives in #216 v1a).

  ## v0 limitations (see arch_wiki/dmh_ai/architecture.md §Browser tools)

    - Vision is OFF: model never sees the page image; it operates from
      a11y tree + extracted text. Screenshots are taken for FE display
      but not sent to the LLM in v0.
    - Single global asyncio lock inside the daemon serialises every
      turn across all users. Two concurrent `browser_task` calls queue.
    - Cookie state is plaintext at `/work/<email>/.browser_state.json`
      under the existing chmod-0700 user-workspace fence.
    - No `evaluate(js)` command — extract structured data via
      `extract_text` with selectors, or call `accessibility_snapshot`.
    - Payment / final-submit clicks are NOT enforcement-gated in v0;
      the system prompt tells the model never to click *Pay* / *Submit
      order* without an explicit `request_input` confirmation. v1b
      (#217) lands the always-confirm gate.
  """

  alias DmhAi.Agent.{AgentSettings, LLM, SessionProgress}
  alias DmhAi.Browser.DaemonClient
  require Logger

  @typedoc "Tool-level result returned to the model."
  @type result :: {:ok, map()} | {:error, String.t()}

  @doc """
  Drive the action loop. `ctx` carries `:user_id`, `:user_email`,
  `:session_id`, `:task_id` (for progress-row attribution).
  """
  @spec run(String.t(), String.t(), String.t() | nil, map()) :: result
  def run(url, goal, constraints, ctx) do
    user_id    = ctx[:user_id] || ctx["user_id"]
    email      = ctx[:user_email] || ctx["user_email"] || ""
    session_id = ctx[:session_id] || ctx["session_id"]

    if not is_binary(user_id) or user_id == "" or
       not is_binary(session_id) or session_id == "" do
      {:error, "browser_task loop: missing user_id/session_id in ctx"}
    else
      state = %{
        user_id:      user_id,
        email:        email,
        session_id:   session_id,
        task_id:      ctx[:task_id] || ctx["task_id"],
        goal:         goal,
        constraints:  constraints || "",
        started_at:   System.monotonic_time(:millisecond),
        screenshot_dir: screenshot_dir(email, session_id),
        max_turns:    AgentSettings.browser_max_turns_per_task(),
        max_runtime:  AgentSettings.browser_max_runtime_ms(),
        screenshots:  AgentSettings.browser_screenshot_enabled(),
        model:        AgentSettings.browser_agent_model()
      }

      File.mkdir_p(state.screenshot_dir)

      case DaemonClient.call("navigate", %{"url" => url}, user_id, email) do
        {:ok, _} ->
          loop(0, [], state)

        {:error, :daemon_unreachable} ->
          {:error,
           "browser_task: the browser daemon is unreachable. Is the sandbox container running and is the bind-mount " <>
             "/data/run/dmh-browser configured? Tell the user this is an operator issue, not a problem they can fix."}

        {:error, {:daemon_error, %{message: msg}}} ->
          if auth_handoff?(msg) do
            handoff(state, msg)
          else
            {:error, "browser_task: initial navigate failed: #{msg}"}
          end

        {:error, reason} ->
          {:error, "browser_task: initial navigate failed: #{inspect(reason)}"}
      end
    end
  end

  # ── loop ────────────────────────────────────────────────────────────────────

  defp loop(turn, _history, %{max_turns: cap}) when turn >= cap do
    {:ok,
     %{
       status: "turn_cap_reached",
       turns: turn,
       reason:
         "Reached the per-task turn cap (#{cap}). Tell the user the goal wasn't completed within the budget; " <>
           "ask whether to retry with a narrower step or call it off."
     }}
  end

  defp loop(turn, history, state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at

    cond do
      elapsed >= state.max_runtime ->
        {:ok,
         %{
           status: "wall_clock_cap_reached",
           turns: turn,
           reason:
             "Hit the wall-clock cap of #{div(state.max_runtime, 1000)}s. Goal not completed; tell the user."
         }}

      true ->
        with {:ok, observation}      <- observe(state),
             screenshot_path         <- maybe_screenshot(turn, state),
             {:ok, decision_json}    <- ask_model(state, observation, history, turn),
             {:ok, decision}         <- parse_decision(decision_json) do
          handle_decision(turn, history, state, decision, screenshot_path)
        else
          {:error, reason} ->
            Logger.warning("[Browser.Loop] turn #{turn} aborted: #{inspect(reason)}")
            {:error, "browser_task turn #{turn}: #{inspect(reason)}"}
        end
    end
  end

  defp handle_decision(turn, _history, state, %{"action" => "complete"} = d, shot_path) do
    emit_progress(state, turn, "complete", %{}, shot_path)
    {:ok, %{
      status: "completed",
      turns: turn + 1,
      reason: Map.get(d, "reason", "model declared completion"),
      summary: Map.get(d, "summary", nil)
    }}
  end

  defp handle_decision(turn, _history, state, %{"action" => "abort"} = d, shot_path) do
    emit_progress(state, turn, "abort", %{}, shot_path)
    {:ok, %{
      status: "aborted",
      turns: turn + 1,
      reason: Map.get(d, "reason", "model declared abort")
    }}
  end

  defp handle_decision(turn, history, state, %{"action" => action, "args" => args} = d, shot_path) do
    emit_progress(state, turn, action, args, shot_path)

    case DaemonClient.call(action, args, state.user_id, state.email) do
      {:ok, result} ->
        loop(turn + 1, append_history(history, d, {:ok, result}), state)

      {:error, {:daemon_error, %{message: msg}}} ->
        if auth_handoff?(msg) do
          handoff(state, msg)
        else
          # Let the model see the error and decide its next move —
          # often it'll pick a different selector or back off. Cheap
          # to give it one shot at self-correction.
          loop(turn + 1, append_history(history, d, {:error, msg}), state)
        end

      {:error, :daemon_unreachable} ->
        {:error, "browser_task: daemon went unreachable mid-task at turn #{turn}"}

      {:error, reason} ->
        loop(turn + 1, append_history(history, d, {:error, inspect(reason)}), state)
    end
  end

  defp handle_decision(_turn, _history, _state, decision, _shot) do
    {:error, "model returned malformed decision: #{inspect(decision)}"}
  end

  # ── observe ─────────────────────────────────────────────────────────────────

  defp observe(state) do
    with {:ok, %{"text" => text} = txt} <-
           DaemonClient.call("extract_text", %{"max_chars" => 10_000}, state.user_id, state.email),
         {:ok, %{"tree" => tree}} <-
           DaemonClient.call("accessibility_snapshot", %{}, state.user_id, state.email) do
      {:ok, %{
        url:  Map.get(txt, "url", ""),
        text: text,
        tree: tree
      }}
    else
      {:error, {:daemon_error, %{message: msg}}} ->
        {:error, "observe failed: #{msg}"}

      err ->
        err
    end
  end

  defp maybe_screenshot(_turn, %{screenshots: false}), do: nil

  defp maybe_screenshot(turn, state) do
    rel_path = "step_#{turn}.png"
    abs_path = Path.join(state.screenshot_dir, rel_path)
    case DaemonClient.call("screenshot", %{"path" => abs_path}, state.user_id, state.email) do
      {:ok, _}     -> rel_path
      {:error, _}  -> nil
    end
  end

  # Sandbox-side path matches host-side because /work is bind-mounted
  # at the same path inside the sandbox. The `Constants` helper for
  # session_workspace_dir returns the master-side path; the sandbox
  # daemon writes there and the FE serves from there via /files.
  defp screenshot_dir(email, session_id) do
    DmhAi.Constants.session_workspace_dir(email, session_id)
    |> Path.join(".browser")
  end

  # ── ask the model ──────────────────────────────────────────────────────────

  defp ask_model(state, observation, history, turn) do
    sys = system_prompt(state)
    user = user_prompt(state, observation, history, turn)

    messages = [
      %{role: "system", content: sys},
      %{role: "user",   content: user}
    ]

    LLM.call(state.model, messages,
      trace: %{origin: "assistant", path: "Browser.Loop.ask_model",
               role: "BrowserAgent", phase: "decide"})
  end

  defp parse_decision({:ok, text}) when is_binary(text) do
    # Models sometimes wrap JSON in ```json fences or prepend prose.
    # Lift out the first {…} block.
    case extract_json(text) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"action" => _} = decision} -> {:ok, decision}
          {:ok, other} -> {:error, "decision missing :action — #{inspect(other)}"}
          {:error, e}  -> {:error, "decision JSON parse: #{inspect(e)} — raw: #{String.slice(text, 0, 200)}"}
        end

      :error ->
        {:error, "no JSON object in model output — raw: #{String.slice(text, 0, 200)}"}
    end
  end

  defp parse_decision({:ok, {:tool_calls, _}}),
    do: {:error, "model emitted tool_calls; the browser loop expects a JSON action object instead"}

  defp parse_decision({:error, reason}),
    do: {:error, "LLM call failed: #{inspect(reason)}"}

  defp extract_json(text) do
    case Regex.run(~r/\{(?:[^{}]|(?R))*\}/u, text) do
      [match] -> {:ok, match}
      _       -> :error
    end
  rescue
    # The recursive regex needs PCRE; fall back to a naive first-{
    # last-} slice if the engine refuses.
    _ ->
      case {:binary.match(text, "{"), :binary.match(text, "}")} do
        {{i, _}, {j, _}} when j > i ->
          {:ok, binary_part(text, i, j - i + 1)}
        _ ->
          :error
      end
  end

  defp append_history(history, decision, result) do
    [%{decision: decision, result: result} | history]
    |> Enum.take(8)  # keep only the last few turns; older context is wasted tokens
  end

  # ── prompts ────────────────────────────────────────────────────────────────

  defp system_prompt(state) do
    """
    You are the action-selection model inside DMH-AI's `browser_task` loop.
    A real Chromium browser is open; you observe each turn and pick ONE next
    action. The user's goal and constraints are restated below.

    GOAL: #{state.goal}
    CONSTRAINTS: #{if state.constraints == "", do: "(none)", else: state.constraints}

    Reply with ONE JSON object — no prose, no code fences. Schema:

      {"action": "<command>", "args": { ... }, "reason": "<one line>"}

    Available commands and their args:

      navigate(url)                           — open a URL
      scroll(amount?: int) | scroll(to_selector: "css")  — scroll viewport
      wait_for_selector(selector, timeout?: ms)
      wait_for_load(state?: "load|domcontentloaded|networkidle")
      extract_text(selector?: "css")          — pulls inner_text
      accessibility_snapshot()                — already provided each observe; no need to call
      click(selector)
      type(selector, text)
      fill(selector, value)                   — for <input>
      select(selector, value)                 — for <select>
      keyboard(key)                           — Enter, Escape, Tab, ArrowDown, etc.
      complete                                — declare the goal done; include `reason` and `summary`
      abort                                   — give up; include `reason`

    Selector rules:
      - Prefer CSS selectors derived from the accessibility tree's role/name.
      - Use unique selectors. If multiple matches, narrow further.
      - Never use raw IDs that look auto-generated (e.g. `#mat-input-1234`); they
        change between page loads. Prefer aria-label, role, name, or stable
        class combinations.

    Hard rules:
      - NEVER click "Pay", "Submit order", "Place order", or any final-checkout
        button. Stop one click before payment and `complete` with a summary
        telling the user the cart is ready for their final approval.
      - NEVER call `evaluate` (not exposed) or guess at JavaScript.
      - When stuck (a selector keeps failing, the page seems to be a login wall
        or captcha), `abort` with a clear reason. Do not loop endlessly.

    The site's URL, current text, and accessibility tree are below for THIS
    turn. Pick ONE action and emit JSON.
    """
  end

  defp user_prompt(_state, observation, history, turn) do
    history_block =
      history
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {%{decision: d, result: r}, i} ->
        "  step -#{i}: " <> Jason.encode!(d) <> " → " <> result_summary(r)
      end)

    history_block =
      if history_block == "", do: "  (none — this is turn 0)", else: history_block

    """
    [TURN #{turn}]
    URL: #{observation.url}

    [PAGE TEXT (first 10 KB)]
    #{observation.text || "(empty)"}

    [ACCESSIBILITY TREE]
    #{Jason.encode!(observation.tree, pretty: true) |> String.slice(0, 6_000)}

    [RECENT ACTIONS]
    #{history_block}

    Emit your next action as JSON. ONE object. No prose around it.
    """
  end

  defp result_summary({:ok, %{"clicked" => sel}}),     do: "clicked #{sel}"
  defp result_summary({:ok, %{"typed" => _}}),         do: "typed"
  defp result_summary({:ok, %{"filled" => _}}),        do: "filled"
  defp result_summary({:ok, %{"selected" => _}}),      do: "selected"
  defp result_summary({:ok, %{"appeared" => sel}}),    do: "appeared: #{sel}"
  defp result_summary({:ok, %{"loaded" => _}}),        do: "loaded"
  defp result_summary({:ok, %{"scrolled_by" => n}}),   do: "scrolled by #{n}"
  defp result_summary({:ok, %{"scrolled_to" => sel}}), do: "scrolled to #{sel}"
  defp result_summary({:ok, %{"url" => url}}),         do: "navigated to #{url}"
  defp result_summary({:ok, _}),                       do: "ok"
  defp result_summary({:error, msg}),                  do: "ERROR: #{String.slice(to_string(msg), 0, 200)}"

  # ── progress / handoff ─────────────────────────────────────────────────────

  defp emit_progress(state, turn, action, args, shot_path) do
    label = "step #{turn}: #{action}#{format_args(args)}"
    label =
      if is_binary(shot_path) and shot_path != "",
        do: label <> " — .browser/#{shot_path}",
        else: label

    progress_ctx = %{
      session_id: state.session_id,
      user_id:    state.user_id,
      task_id:    state.task_id
    }
    _ = SessionProgress.append(progress_ctx, "browser_step", label)
    :ok
  end

  defp format_args(args) when is_map(args) and map_size(args) == 0, do: "()"

  defp format_args(args) when is_map(args) do
    summary =
      args
      |> Map.take(["selector", "url", "text", "value", "key", "to_selector", "amount"])
      |> Enum.map_join(", ", fn {k, v} ->
        "#{k}=#{inspect(v) |> String.slice(0, 80)}"
      end)

    "(#{summary})"
  end

  defp format_args(_), do: ""

  # Heuristic: on these substrings the daemon's error indicates a
  # blocking gate the model can't solve from inside the sandbox
  # browser. Real handoff lands in #216 v1a (noVNC); for v0 we
  # surface the situation cleanly so the user knows to log in via
  # their own browser and retry.
  defp auth_handoff?(msg) when is_binary(msg) do
    lower = String.downcase(msg)
    Enum.any?(
      ~w(captcha cloudflare challenge are_you_human ddos protection
         enable_javascript please_wait verify human),
      &String.contains?(lower, &1)
    )
  end

  defp auth_handoff?(_), do: false

  defp handoff(state, why) do
    progress_ctx = %{
      session_id: state.session_id,
      user_id:    state.user_id,
      task_id:    state.task_id
    }
    _ = SessionProgress.append(progress_ctx, "browser_step",
          "auth handoff: #{String.slice(why, 0, 200)}")

    {:ok,
     %{
       status: "auth_handoff_required",
       reason:
         "The site put up a captcha or login wall the agent can't solve from inside the sandbox. " <>
           "Tell the user: open the same site in their own browser, complete the challenge / log in, then retry — " <>
           "their cookies are persisted across calls so the browser_task's next attempt won't re-prompt.",
       v1a_pending: true,
       upstream: String.slice(why, 0, 300)
     }}
  end
end
