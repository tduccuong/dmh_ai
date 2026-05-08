# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Browser.Loop do
  @moduledoc """
  Phase 3 of #215 — observe→ask→act loop driving the sandbox-side
  browser daemon (`Browser.DaemonClient`) on behalf of `Tools.BrowserNavigate`.

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
    append a sub_label to the parent BrowserNavigate progress row
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
      the compact a11y view + extracted text (see arch_wiki/dmh_ai/
      architecture.md §"Observation payload sizing"). Screenshots are
      taken for FE display but not sent to the LLM in v0.
    - Single global asyncio lock inside the daemon serialises every
      turn across all users. Two concurrent `browser_navigate` calls queue.
    - Cookie state is plaintext at
      `/data/user_workspaces/<email>/.browser_state.json` under the
      existing chmod-0700 user-workspace fence.
    - No `evaluate(js)` command — extract structured data via
      `extract_text` with selectors, or call `accessibility_snapshot`.
    - Payment / final-submit clicks are NOT enforcement-gated in v0;
      the system prompt tells the model never to click *Pay* / *Submit
      order* without an explicit `request_input` confirmation. v1b
      (#217) lands the always-confirm gate.
  """

  alias DmhAi.Agent.{AgentSettings, LLM, SessionProgress, TokenTracker}
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
      {:error, "browser_navigate loop: missing user_id/session_id in ctx"}
    else
      state = %{
        user_id:         user_id,
        email:           email,
        session_id:      session_id,
        task_id:         ctx[:task_id] || ctx["task_id"],
        # Parent `kind: tool` row id, threaded by execute_tools/3. Each
        # browser-step appends its human-readable label as a sub_label
        # on this row (same render path as web_search), so the FE shows
        # per-step activity nested under the parent BrowserNavigate row
        # rather than as flat siblings.
        progress_row_id: ctx[:progress_row_id] || ctx["progress_row_id"],
        goal:            goal,
        constraints:     constraints || "",
        started_at:      System.monotonic_time(:millisecond),
        # Master and sandbox bind-mount the workspaces tree at the same
        # container path, so a single screenshot_dir works for both
        # File.mkdir_p on master and as the path arg in the daemon's
        # screenshot command.
        screenshot_dir: screenshot_dir(email, session_id),
        max_turns:       AgentSettings.browser_max_turns_per_task(),
        max_runtime:     AgentSettings.browser_max_runtime_ms(),
        screenshots:     AgentSettings.browser_screenshot_enabled(),
        model:           AgentSettings.browser_agent_model()
      }

      File.mkdir_p(state.screenshot_dir)

      case DaemonClient.call("navigate", %{"url" => url}, user_id, email) do
        {:ok, _} ->
          loop(0, [], state)

        {:error, :daemon_unreachable} ->
          {:error,
           "browser_navigate: the browser daemon is unreachable. Is the sandbox container running and is the bind-mount " <>
             "/data/run/dmh-browser configured? Tell the user this is an operator issue, not a problem they can fix."}

        {:error, {:daemon_error, %{message: msg}}} ->
          if auth_handoff?(msg) do
            handoff(state, msg)
          else
            {:error, "browser_navigate: initial navigate failed: #{msg}"}
          end

        {:error, reason} ->
          {:error, "browser_navigate: initial navigate failed: #{inspect(reason)}"}
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
        with screenshot_path       <- maybe_screenshot(turn, state),
             {:ok, observation}    <- observe(state, screenshot_path),
             {:ok, decision_json}  <- ask_model(state, observation, history, turn) do
          case parse_decision(decision_json) do
            {:ok, decision} ->
              handle_decision(turn, history, state, decision, screenshot_path)

            {:error, parse_err} ->
              # Don't abort the whole tool on one bad decision. Append
              # the parse error to history so the model SEES its own
              # malformed output on the next turn — it almost always
              # self-corrects (most common case: emitting `args:
              # {".css-selector"}` instead of `args: {"selector": "…"}`).
              # Without this self-correction loop, a single bad emit
              # killed the whole `browser_navigate` invocation and the
              # outer Assistant fell back to `web_fetch` blind.
              Logger.warning("[Browser.Loop] turn #{turn} bad JSON, retrying: #{inspect(parse_err)}")
              loop(
                turn + 1,
                append_history(history, %{"action" => "MALFORMED"}, {:error, parse_err}),
                state
              )
          end
        else
          {:error, :vision_unavailable, reason} ->
            # Vision pre-processor is offline OR rejected the image
            # (e.g., configured swiftModel is text-only). Don't let the
            # action LLM free-style a recovery — surface honestly to
            # the outer Assistant, which relays to the user.
            Logger.warning("[Browser.Loop] turn #{turn} vision_unavailable: #{reason}")
            {:ok,
             %{
               status: "vision_unavailable",
               turns:  turn,
               reason: reason
             }}

          {:error, reason} ->
            Logger.warning("[Browser.Loop] turn #{turn} aborted: #{inspect(reason)}")
            {:error, "browser_navigate turn #{turn}: #{inspect(reason)}"}
        end
    end
  end

  defp handle_decision(turn, _history, state, %{"action" => "complete"} = d, shot_path) do
    emit_progress(state, turn, d, shot_path)
    {:ok, %{
      status: "completed",
      turns: turn + 1,
      reason: Map.get(d, "reason", "model declared completion"),
      summary: Map.get(d, "summary", nil)
    }}
  end

  defp handle_decision(turn, _history, state, %{"action" => "abort"} = d, shot_path) do
    emit_progress(state, turn, d, shot_path)
    {:ok, %{
      status: "aborted",
      turns: turn + 1,
      reason: Map.get(d, "reason", "model declared abort")
    }}
  end

  defp handle_decision(turn, history, state, %{"action" => action, "args" => args} = d, shot_path) do
    emit_progress(state, turn, d, shot_path)

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
        {:error, "browser_navigate: daemon went unreachable mid-task at turn #{turn}"}

      {:error, reason} ->
        loop(turn + 1, append_history(history, d, {:error, inspect(reason)}), state)
    end
  end

  defp handle_decision(_turn, _history, _state, decision, _shot) do
    {:error, "model returned malformed decision: #{inspect(decision)}"}
  end

  # ── observe (vision-distilled, Shape 4) ────────────────────────────────────

  # Per-turn observation pipeline:
  #   1. Read the just-captured screenshot PNG from disk.
  #   2. Run a small vision-capable LLM (`browserDistillModel`) over it
  #      with the user's goal as context, getting back a JSON
  #      summary + relevant_elements list.
  #   3. Action LLM consumes ONLY that JSON. Per-turn `extract_text` /
  #      `accessibility_snapshot` calls into the daemon are no longer
  #      part of observe — the action LLM may still call them
  #      explicitly when it needs verbatim text from a specific
  #      selector.
  #
  # Failure mode: if the screenshot is missing or the distill LLM call
  # fails / returns malformed JSON, fall back to a placeholder distilled
  # JSON noting the failure. The action LLM then has to drive blind
  # (or call accessibility_snapshot itself) but the loop keeps running
  # rather than aborting the whole tool.
  defp observe(_state, nil) do
    {:error, :vision_unavailable,
     "Cannot run a browser_navigate without screenshots — `browserScreenshotEnabled` is off " <>
       "OR the screenshot capture failed. Vision-distillation requires the per-turn PNG. " <>
       "Tell the user honestly and ask whether to enable screenshots and retry."}
  end

  defp observe(state, rel_path) when is_binary(rel_path) do
    abs_path = Path.join(state.screenshot_dir, rel_path)

    case File.read(abs_path) do
      {:ok, _png_bytes} ->
        case distill(state, abs_path) do
          {:ok, json} ->
            {:ok, %{url: current_url(state), distilled: json}}

          {:error, :vision_unavailable, reason} ->
            {:error, :vision_unavailable, reason}
        end

      {:error, reason} ->
        Logger.warning("[Browser.Loop] could not read screenshot #{abs_path}: #{inspect(reason)}")
        {:error, :vision_unavailable,
         "Screenshot file not readable: #{inspect(reason)}. Tell the user honestly; ask whether to retry."}
    end
  end

  # Best-effort URL fetch — the daemon's most recent navigate response
  # carried the URL; we hold it on state once it lands. Falls back to
  # the start_url for turn 0.
  defp current_url(state), do: Map.get(state, :url, "")

  # Cap the side fed to the vision LLM. The Playwright daemon captures
  # at native viewport (~1280×800); that's wasteful both for the wire
  # (~120 KB base64) and for the vision API's tile budget. 1024 wide is
  # enough for the LLM to read button labels and headings while keeping
  # the payload under 70 KB.
  @distill_max_side 1024

  defp distill(state, screenshot_abs_path) when is_binary(screenshot_abs_path) do
    model = AgentSettings.browser_distill_model()

    case resize_for_vision(screenshot_abs_path) do
      {:ok, png_bytes} ->
        do_distill(state, model, png_bytes)

      {:error, reason} ->
        {:error, :vision_unavailable,
         "Could not prepare screenshot for vision pre-processor: #{reason}. " <>
           "Tell the user honestly; ask whether to retry."}
    end
  end

  defp do_distill(state, model, png_bytes) do
    sys_prompt = """
    You are a vision pre-processor inside a browser-agent loop. Examine
    the screenshot. Identify what's relevant to the agent's goal. Reply
    with ONE JSON object — no prose, no code fences:

      {
        "summary":           "<one paragraph: what is on this page right now>",
        "relevant_elements": [
          {"label": "<exact visible text or accessible name>",
           "role":  "<button | link | textbox | checkbox | …>"},
          … 3-7 entries …
        ],
        "blocking":          null
      }

    DO NOT invent CSS selectors, IDs, classes, or `data-*` attributes —
    you can ONLY see the rendered pixels, not the DOM, so any selector
    you guess will be wrong. Report only what you can READ from the
    screenshot: the visible label text and the apparent role. The
    downstream action LLM will derive a real selector from the live
    accessibility tree using your label.

    Use `blocking` to flag a captcha / login wall / cookie modal that
    must be cleared before the goal can progress; otherwise null.
    Stay concise — this is fed verbatim to a downstream action LLM.
    """

    user_text = """
    Goal: #{state.goal}
    Constraints: #{if state.constraints == "", do: "(none)", else: state.constraints}
    """

    image_url = "data:image/png;base64," <> Base.encode64(png_bytes)

    # OpenAI-format vision message: content is a list of typed blocks.
    user_msg = %{
      role: "user",
      content: [
        %{type: "text",      text: user_text},
        %{type: "image_url", image_url: %{url: image_url, detail: "auto"}}
      ]
    }

    messages = [%{role: "system", content: sys_prompt}, user_msg]

    on_tokens = fn rx, tx ->
      DmhAi.Agent.TokenTracker.add_master(state.session_id, state.user_id, rx, tx)
    end

    trace = %{origin: "assistant", path: "Browser.Loop.distill",
              role: "BrowserDistiller", phase: "distill"}

    case LLM.call(model, messages, on_tokens: on_tokens, trace: trace) do
      {:ok, text} when is_binary(text) and text != "" ->
        case parse_distill_payload(text) do
          {:ok, json_str} ->
            {:ok, json_str}

          {:error, why} ->
            Logger.warning(
              "[Browser.Loop] distill payload unparseable (#{why}); raw=#{String.slice(text, 0, 400)}"
            )

            {:error, :vision_unavailable,
             "Browser navigation stuck on invalid distilled data — #{why}. " <>
               "Tell the user verbatim: \"Browser navigation stuck on invalid distilled data\" " <>
               "and stop. Do not retry on your own."}
        end

      other ->
        Logger.warning("[Browser.Loop] distill LLM call failed: #{inspect(other, limit: 80)}")
        {:error, :vision_unavailable,
         "Vision pre-processor LLM call failed (#{inspect(elem(other, 1), limit: 80)}). " <>
           "The configured `swiftModel` may not support image input, or the upstream model is " <>
           "unreachable. Tell the user honestly; ask whether to switch the swiftModel setting " <>
           "or retry. Do NOT attempt to navigate elsewhere or guess at the page state."}
    end
  end

  # Parse and validate the vision LLM's distillation reply. The model is
  # instructed to return ONE JSON object ({summary, relevant_elements,
  # blocking}), no fences. In practice it sometimes returns:
  #
  #   - the JSON wrapped in ```json … ``` fences
  #   - JS-style line comments (// like this) after array entries
  #   - block comments (/* … */)
  #   - trailing commas before } or ]
  #   - `blocking` as an object {type, message} instead of null|string
  #   - elements missing `label` or `role`
  #
  # Rather than abort the whole browse loop on any of these, we sanitise
  # and normalise. Only when the payload is genuinely unsalvageable
  # (no JSON, decode fails, required fields wrong-typed) do we surface
  # `:vision_unavailable` with a "Browser navigation stuck on invalid
  # distilled data" message the assistant relays verbatim to the user.
  defp parse_distill_payload(text) do
    with {:ok, raw}        <- find_json_object(text),
         sanitised          = sanitise_jsonish(raw),
         {:ok, decoded}     <- decode_or_explain(sanitised),
         {:ok, normalised}  <- normalise_distill_shape(decoded) do
      {:ok, Jason.encode!(normalised, pretty: true)}
    end
  end

  defp find_json_object(text) do
    case extract_json(text) do
      {:ok, json} -> {:ok, json}
      :error      -> {:error, "no JSON object found in vision pre-processor reply"}
    end
  end

  defp decode_or_explain(json) do
    case Jason.decode(json) do
      {:ok, m}             -> {:ok, m}
      {:error, %Jason.DecodeError{position: pos}} ->
        {:error, "JSON decode failed near position #{pos} (after sanitising fences/comments/trailing commas)"}
      {:error, _}          -> {:error, "JSON decode failed"}
    end
  end

  # Strip JS-isms that the vision model sometimes emits inside an
  # otherwise-JSON payload. Comment-stripping is STRING-AWARE — it walks
  # the input char by char tracking whether the cursor is inside a JSON
  # string literal, so a `//` or `/*` inside a `"label"` value (think
  # URLs in labels, or the literal text "// please fill in") is not
  # eaten by the strip.
  defp sanitise_jsonish(json) do
    json
    |> strip_comments_string_aware()
    |> strip_trailing_commas()
  end

  defp strip_comments_string_aware(input), do: do_strip_comments(input, [], :code)

  defp do_strip_comments(<<>>, acc, _),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # Inside a string: handle backslash-escapes so `\"` doesn't look like
  # a string terminator.
  defp do_strip_comments(<<"\\", c::utf8, rest::binary>>, acc, :str),
    do: do_strip_comments(rest, [<<c::utf8>>, "\\" | acc], :str)

  defp do_strip_comments(<<"\"", rest::binary>>, acc, :str),
    do: do_strip_comments(rest, ["\"" | acc], :code)

  defp do_strip_comments(<<c::utf8, rest::binary>>, acc, :str),
    do: do_strip_comments(rest, [<<c::utf8>> | acc], :str)

  # In code mode: detect string starts and comments.
  defp do_strip_comments(<<"\"", rest::binary>>, acc, :code),
    do: do_strip_comments(rest, ["\"" | acc], :str)

  defp do_strip_comments(<<"//", rest::binary>>, acc, :code) do
    case :binary.split(rest, "\n") do
      [_, after_nl] -> do_strip_comments(after_nl, ["\n" | acc], :code)
      [_]           -> do_strip_comments(<<>>, acc, :code)
    end
  end

  defp do_strip_comments(<<"/*", rest::binary>>, acc, :code) do
    case :binary.split(rest, "*/") do
      [_, after_block] -> do_strip_comments(after_block, acc, :code)
      [_]              -> do_strip_comments(<<>>, acc, :code)
    end
  end

  defp do_strip_comments(<<c::utf8, rest::binary>>, acc, :code),
    do: do_strip_comments(rest, [<<c::utf8>> | acc], :code)

  # Trailing comma before `}` or `]` is JS-permissive but invalid JSON.
  # The simple regex form would match inside string literals too; in
  # the distill payload labels can contain `,` followed by space and
  # `]`/`}` only by extreme bad luck, so we accept that risk for now.
  defp strip_trailing_commas(input),
    do: String.replace(input, ~r/,(\s*[}\]])/, "\\1")

  # Normalise to the canonical shape the action LLM expects.
  # Required: `summary` (string), `relevant_elements` (list).
  # Optional: `blocking` (null|string|object-with-message).
  defp normalise_distill_shape(m) when is_map(m) do
    summary  = Map.get(m, "summary")
    elements = Map.get(m, "relevant_elements")

    cond do
      not is_binary(summary) ->
        {:error, "missing or non-string `summary` field"}

      not is_list(elements) ->
        {:error, "missing or non-list `relevant_elements` field"}

      true ->
        normalised_elements =
          elements
          |> Enum.map(&normalise_element/1)
          |> Enum.reject(&is_nil/1)

        {:ok,
         %{
           "summary"           => summary,
           "relevant_elements" => normalised_elements,
           "blocking"          => normalise_blocking(Map.get(m, "blocking"))
         }}
    end
  end

  defp normalise_distill_shape(_),
    do: {:error, "top-level distill payload is not a JSON object"}

  defp normalise_element(%{"label" => l, "role" => r}) when is_binary(l) and is_binary(r),
    do: %{"label" => l, "role" => r}

  defp normalise_element(_), do: nil

  defp normalise_blocking(nil), do: nil
  defp normalise_blocking(""),  do: nil
  defp normalise_blocking(s) when is_binary(s), do: s
  defp normalise_blocking(%{"message" => m}) when is_binary(m), do: m
  defp normalise_blocking(%{"reason"  => m}) when is_binary(m), do: m
  defp normalise_blocking(_), do: nil

  # Shrink the screenshot before base64-encoding for the vision LLM.
  # Uses libvips' `vipsthumbnail` (in master image — see code/Dockerfile):
  # ~10× faster than ImageMagick on PNG resize, single-purpose, no
  # subprocess dependency chain. Output written to a tmp file; read back
  # then deleted. On any failure, returns the error so the caller can
  # surface it to the user (rather than silently sending a giant payload).
  defp resize_for_vision(in_path) when is_binary(in_path) do
    out_path = Path.join(System.tmp_dir!(), "dmh-shot-distill-#{:erlang.unique_integer([:positive])}.png")

    try do
      case System.cmd("vipsthumbnail",
             [in_path, "-s", to_string(@distill_max_side), "-o", out_path],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          File.read(out_path)

        {err, code} ->
          {:error, "vipsthumbnail exit #{code}: #{String.slice(to_string(err), 0, 200)}"}
      end
    rescue
      e -> {:error, "vipsthumbnail rescue: #{Exception.message(e)}"}
    after
      _ = File.rm(out_path)
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

  # `.browser/` path under the session's workspace. Same path on master
  # and inside the sandbox — both containers bind-mount the workspaces
  # tree at the same container address.
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

    # Per-turn LLM tokens land on the master bucket of the same session
    # — same as the outer Assistant chain. Without this every
    # Browser.Loop turn is invisible to `session_token_stats`, which is
    # misleading since the loop can easily burn 5–15k tokens per turn
    # (12k-char observation + history) and run dozens of turns.
    on_tokens = fn rx, tx ->
      TokenTracker.add_master(state.session_id, state.user_id, rx, tx)
    end

    LLM.call(state.model, messages,
      on_tokens: on_tokens,
      trace: %{origin: "assistant", path: "Browser.Loop.ask_model",
               role: "BrowserAgent", phase: "decide"})
  end

  # Caller (`with {:ok, decision_json} <- ask_model(...)`) has already
  # unwrapped the LLM's `{:ok, ...}` tuple, so we receive the raw value:
  # either a text string or a `{:tool_calls, list}` tuple. The earlier
  # `{:error, _}` clause is unreachable from `with` (the else branch
  # short-circuits errors directly).
  defp parse_decision(text) when is_binary(text) do
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

  defp parse_decision({:tool_calls, _}),
    do: {:error, "model emitted tool_calls; the browser loop expects a JSON action object instead"}

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
    You are the action-selection model inside DMH-AI's `browser_navigate` loop.
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
      extract_text(selector?: "css")          — pulls all matching inner_text
                                                 from the live page; useful when
                                                 the distilled view is missing
                                                 a specific text block you need
                                                 verbatim
      accessibility_snapshot(selector?: "css") — read structural a11y tree of
                                                 the page or a subtree; useful
                                                 when the distilled view didn't
                                                 surface the element you want
                                                 to act on
      click(selector)
      type(selector, text)
      fill(selector, value)                   — for <input>
      select(selector, value)                 — for <select>
      keyboard(key)                           — Enter, Escape, Tab, ArrowDown, etc.
      complete                                — declare the goal done; include `reason` and `summary`
      abort                                   — give up; include `reason`

    Selector rules:
      - The distilled view gives you LABELS + ROLES (visible text +
        button/link/etc.) — it does NOT and CANNOT give you CSS
        selectors. Vision can only see rendered pixels, never the DOM.
      - To derive a real selector from a distilled label, call
        `accessibility_snapshot` (whole page or a subtree) — that
        result lists every `role "<accessible name>"` the page actually
        exposes. Match the distilled label to a role+name in the
        snapshot, then derive a Playwright selector from it. Examples:
          - `button "Akzeptieren"` →  `button:has-text("Akzeptieren")`
            (Playwright pseudo-selector — works in this runtime)
          - `link "Mein Konto"`    →  `a:has-text("Mein Konto")`
          - `textbox "Email"`      →  `input[aria-label="Email"]`
            or `input[name="email"]` if the snapshot reveals it.
      - Do NOT invent IDs, classes, or `data-*` attributes that the
        snapshot didn't actually show — every selector you emit must
        either come from the live a11y snapshot for THIS page, or be a
        text/role pseudo-selector built from a label you just saw in
        the distilled view.
      - Use unique selectors. If multiple matches, narrow further by
        scoping to a parent role (`dialog button:has-text("Akzeptieren")`).
      - Never use raw IDs that look auto-generated
        (e.g. `#mat-input-1234`) — they change between page loads.

    Hard rules:
      - NEVER click "Pay", "Submit order", "Place order", or any final-checkout
        button. Stop one click before payment and `complete` with a summary
        telling the user the cart is ready for their final approval.
      - NEVER call `evaluate` (not exposed) or guess at JavaScript.
      - When stuck (a selector keeps failing, the page seems to be a login wall
        or captcha), `abort` with a clear reason. Do not loop endlessly.

    The page's URL and a vision-distilled JSON view of the page are below
    for THIS turn — the distilled view is produced by a vision pre-pass
    over the screenshot and lists the elements most relevant to your goal.
    Pick ONE action and emit JSON.
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

    [DISTILLED VIEW]
    #{observation.distilled}

    [RECENT ACTIONS]
    #{history_block}

    Emit your next action as JSON. ONE object. No prose around it.
    """
  end

  # Action-result feedback for the model's `[RECENT ACTIONS]` history
  # block. Order matters: data-bearing keys MUST precede `url`, because
  # the daemon's `extract_text` and `accessibility_snapshot` results
  # also include the page url alongside the actual payload. Without the
  # data-bearing clauses up here, the `url` clause below would match
  # first and the model would see "navigated to …" for an extract call —
  # actively misleading, and the cause of the 49-turn extract_text loop
  # observed on Hacker News.
  defp result_summary({:ok, %{"text" => t, "matches" => n}}) when is_binary(t) and is_integer(n) do
    suffix = if n == 1, do: "", else: "es"
    "text (#{n} match#{suffix}): " <> (t |> String.replace(~r/\s+/, " ") |> String.slice(0, 300))
  end

  defp result_summary({:ok, %{"text" => t}}) when is_binary(t),
    do: "text: " <> (t |> String.replace(~r/\s+/, " ") |> String.slice(0, 300))

  defp result_summary({:ok, %{"view" => v} = m}) when is_binary(v) do
    trunc_note = if Map.get(m, "truncated"), do: " [view truncated]", else: ""
    "view: " <> String.slice(v, 0, 300) <> trunc_note
  end

  defp result_summary({:ok, %{"clicked"     => sel}}),    do: "clicked #{sel}"
  defp result_summary({:ok, %{"typed"       => _}}),      do: "typed"
  defp result_summary({:ok, %{"filled"      => _}}),      do: "filled"
  defp result_summary({:ok, %{"selected"    => _}}),      do: "selected"
  defp result_summary({:ok, %{"appeared"    => sel}}),    do: "appeared: #{sel}"
  defp result_summary({:ok, %{"loaded"      => _}}),      do: "loaded"
  defp result_summary({:ok, %{"scrolled_by" => n}}),      do: "scrolled by #{n}"
  defp result_summary({:ok, %{"scrolled_to" => sel}}),    do: "scrolled to #{sel}"
  defp result_summary({:ok, %{"path"        => p}}),      do: "screenshot: #{p}"
  defp result_summary({:ok, %{"pressed"     => k}}),      do: "pressed #{k}"
  defp result_summary({:ok, %{"pong"        => _}}),      do: "pong"

  defp result_summary({:ok, %{"url" => url, "title" => title}}) when is_binary(title) and title != "",
    do: "navigated to #{url} (#{title})"
  defp result_summary({:ok, %{"url" => url}}),         do: "navigated to #{url}"

  # Future-proof catch-all: dump the result as JSON instead of "ok",
  # so any future daemon command's return shape is visible to the model
  # rather than silently collapsing to a content-free placeholder. (The
  # silent-collapse failure mode was what hid the misleading match
  # for as long as it did.)
  defp result_summary({:ok, m}) when is_map(m) do
    case Jason.encode(m) do
      {:ok, j} -> "ok: " <> String.slice(j, 0, 300)
      _        -> "ok"
    end
  end
  defp result_summary({:ok, _}),       do: "ok"
  defp result_summary({:error, msg}),  do: "ERROR: #{String.slice(to_string(msg), 0, 200)}"

  # ── progress / handoff ─────────────────────────────────────────────────────

  # Append a human-readable activity label to the parent BrowserNavigate
  # progress row's `sub_labels` JSON array — same render path web_search
  # uses for its SearXNG-fanout sub-activity. The FE rotates through the
  # parent's sub_labels and renders them indented under the parent row,
  # so per-step browser activity reads as nested under the BrowserNavigate
  # tool call rather than as flat siblings of unrelated tools.
  #
  # Label shape (from highest-fidelity to fallback):
  #   1. The model's `reason` field — its own natural-language summary
  #      of the step (e.g. "Read the first story's title"). Best signal.
  #   2. A canned "<verb> <key-arg>" phrase when no reason was supplied
  #      (e.g. "Opening https://shop-apotheke.com", "Reading page text").
  #   3. The bare action name as final fallback.
  #
  # Screenshot path is appended only when present; the FE renders it
  # as a separate cell after the textual label.
  defp emit_progress(state, turn, decision, shot_path) when is_map(decision) do
    action = Map.get(decision, "action", "?")
    reason = decision |> Map.get("reason") |> normalize_reason()

    base_label =
      cond do
        reason != "" -> reason
        true         -> action_verb_phrase(action, Map.get(decision, "args", %{}))
      end

    label = "step #{turn}: #{base_label}"

    label =
      if is_binary(shot_path) and shot_path != "" do
        label <> " — .browser/#{shot_path}"
      else
        label
      end

    SessionProgress.append_sub_label(state.progress_row_id, label)
    :ok
  end

  defp normalize_reason(nil), do: ""
  defp normalize_reason(s) when is_binary(s), do: s |> String.trim() |> String.slice(0, 200)
  defp normalize_reason(_), do: ""

  # Compact action-only fallback when the model didn't supply a reason.
  # Pick the most informative argument for the verb.
  defp action_verb_phrase("navigate", %{"url" => url}) when is_binary(url),
    do: "Opening #{url}"
  defp action_verb_phrase("navigate", _), do: "Navigating"
  defp action_verb_phrase("click", %{"selector" => sel}) when is_binary(sel),
    do: "Clicking " <> sel
  defp action_verb_phrase("click", _), do: "Clicking"
  defp action_verb_phrase(verb, %{"selector" => sel}) when verb in ["type", "fill", "select"] and is_binary(sel),
    do: String.capitalize(verb) <> " into " <> sel
  defp action_verb_phrase("scroll", %{"to_selector" => sel}) when is_binary(sel),
    do: "Scrolling to " <> sel
  defp action_verb_phrase("scroll", _), do: "Scrolling"
  defp action_verb_phrase("extract_text", _), do: "Reading page text"
  defp action_verb_phrase("accessibility_snapshot", _), do: "Reading page structure"
  defp action_verb_phrase("wait_for_selector", %{"selector" => sel}) when is_binary(sel),
    do: "Waiting for " <> sel
  defp action_verb_phrase("wait_for_load", _), do: "Waiting for page load"
  defp action_verb_phrase("keyboard", %{"key" => k}) when is_binary(k),
    do: "Pressing " <> k
  defp action_verb_phrase("complete", _), do: "Done"
  defp action_verb_phrase("abort", _), do: "Giving up"
  defp action_verb_phrase(other, _), do: to_string(other)

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
    SessionProgress.append_sub_label(
      state.progress_row_id,
      "auth handoff: #{String.slice(why, 0, 200)}"
    )

    {:ok,
     %{
       status: "auth_handoff_required",
       reason:
         "The site put up a captcha or login wall the agent can't solve from inside the sandbox. " <>
           "Tell the user: open the same site in their own browser, complete the challenge / log in, then retry — " <>
           "their cookies are persisted across calls so the browser_navigate's next attempt won't re-prompt.",
       v1a_pending: true,
       upstream: String.slice(why, 0, 300)
     }}
  end
end
