# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Browser.Loop do
  @moduledoc """
  Set-of-Marks action loop driving the sandbox-side browser daemon
  on behalf of `Tools.BrowserNavigate`. See
  `arch_wiki/dmh_ai/architecture.md` §"Browser tools" for the full
  contract.

  Per-turn flow:

      1. observe      daemon enumerates visible interactives, paints
                      a magenta box + numeric index around each, and
                      returns the annotated viewport + descriptor list
      2. compose      master assembles the Navigator message:
                        [annotated image, observation text incl. ELEMENTS]
      3. ask_action   single Navigator-tier LLM call → action JSON
      4. dispatch     master forwards verb to daemon (or terminates)
      5. record       master appends {action, args, success?} history
      6. detect       stuck_action streak? turn / runtime cap? → halt

  Halt conditions, priority order:
    1. `complete` verb        → status `"completed"`
    2. `abort` verb           → status `"aborted"`
    3. `stuck_action`         → status `"stuck_action"`
    4. `turn ≥ browserMaxTurnsPerTask` → status `"turn_cap"`
    5. wall ≥ `browserMaxRuntimeMs`    → status `"runtime_cap"`

  The model targets elements by `index` from the magenta-labelled
  ELEMENTS list — not by pixel coordinates. Indices are valid only
  for the turn's observation; every state-mutating verb invalidates
  the daemon's `idx → ElementHandle` map, and a subsequent indexed
  verb without a fresh `observe` returns `stale_index` (handled as a
  soft failure, not a halt). The master runs `observe` at the start
  of every turn, so the model always sees fresh indices.
  """

  alias DmhAi.Browser.DaemonClient
  alias DmhAi.Agent.{AgentSettings, LLM, SessionProgress}
  require Logger

  @type ctx :: %{
          required(:user_id) => String.t(),
          required(:user_email) => String.t(),
          required(:session_id) => String.t(),
          optional(:task_id) => String.t() | nil,
          optional(:progress_row_id) => integer() | nil,
          optional(:client_viewport) => %{w: pos_integer(), h: pos_integer(),
                                           is_mobile: boolean()} | nil
        }

  @typedoc "Tool-level result returned to the upstream assistant LLM."
  @type result :: {:ok, map()} | {:error, String.t()}

  # How many trailing actions to render in the RECENT ACTIONS block.
  # Tightly coupled to the system prompt's "last 5" line — change both
  # together.
  @recent_actions_window 5

  @doc """
  Drive the action loop. `ctx` carries `:user_id`, `:user_email`,
  `:session_id`, `:task_id`, `:progress_row_id`, `:client_viewport`.
  """
  @spec run(String.t(), String.t(), String.t() | nil, ctx()) :: result()
  def run(url, goal, constraints, ctx)
      when is_binary(url) and is_binary(goal) and is_map(ctx) do
    state = init_state(url, goal, constraints, ctx)

    case DaemonClient.call("navigate", navigate_args(url), daemon_ctx(state)) do
      {:ok, nav} ->
        append_step(state, "goto #{url}")

        # `wait_until=domcontentloaded` (the navigate strategy) fires
        # before JS-rendered widgets exist on heavy SPAs (react-hydrated
        # booking forms, dynamically injected consent libraries). Without
        # this settle the first `observe` returns an empty ELEMENTS list
        # and the model burns turn 0 on a blind scroll.
        Process.sleep(AgentSettings.browser_initial_settle_ms())

        state
        |> Map.put(:last_url, nav["url"])
        |> Map.put(:last_title, nav["title"])
        |> loop()

      {:error, reason} ->
        {:ok,
         %{
           status: "aborted",
           turns: 0,
           summary: "Initial navigation failed: #{format_error(reason)}"
         }}
    end
  end

  # ── state ─────────────────────────────────────────────────────────────────

  defp init_state(url, goal, constraints, ctx) do
    %{
      start_url: url,
      goal: goal,
      constraints: constraints || "",
      user_id: ctx[:user_id],
      user_email: ctx[:user_email],
      session_id: ctx[:session_id],
      progress_row_id: ctx[:progress_row_id],
      client_viewport: ctx[:client_viewport],
      turn: 0,
      last_url: nil,
      last_title: nil,
      # Most recent observation's element descriptor list. The Loop
      # uses this only for prettifying RECENT ACTIONS (looking up the
      # label of an indexed element after the fact); the daemon owns
      # the authoritative idx → ElementHandle map.
      last_elements: [],
      # Most recent action first (prepended).
      history: [],
      # Last extract_text result text — piped into the next observation's
      # EXTRACTED_TEXT block. Cleared by any non-extract action.
      last_extract: nil,
      # Stuck-action detector. Counts consecutive identical
      # `{verb, args}` pairs whose dispatch FAILED (daemon error,
      # stale_index). Successful actions reset the count: a model
      # repeating an action that the daemon accepted is making real
      # forward progress (different DOM state each turn) and shouldn't
      # be halted on the args alone. The runtime / turn cap catches
      # genuine no-progress loops.
      action_streak: %{prev_key: nil, count: 0},
      start_ms: System.monotonic_time(:millisecond)
    }
  end

  # Build the per-call ctx that DaemonClient.call accepts.
  defp daemon_ctx(state) do
    %{
      user_id: state.user_id,
      session_id: state.session_id,
      email: state.user_email,
      viewport: state.client_viewport
    }
  end

  # ── main loop ─────────────────────────────────────────────────────────────

  defp loop(state) do
    max_turns = AgentSettings.browser_max_turns_per_task()
    max_runtime = AgentSettings.browser_max_runtime_ms()

    cond do
      state.turn >= max_turns ->
        finalize(state, "turn_cap",
          "Hit turn cap (#{state.turn} turns) before completing the goal.")

      elapsed_ms(state) >= max_runtime ->
        finalize(state, "runtime_cap",
          "Hit wall-clock cap (#{div(max_runtime, 1_000)}s) before completing the goal.")

      true ->
        run_turn(state)
    end
  end

  defp run_turn(state) do
    case DaemonClient.call("observe", %{}, daemon_ctx(state)) do
      {:ok, snap} ->
        state =
          state
          |> Map.put(:last_url, snap["url"])
          |> Map.put(:last_title, snap["title"])
          |> Map.put(:last_elements, snap["elements"] || [])

        observation_text = build_observation(state, snap)

        case ask_action(observation_text, snap, state) do
          {:ok, %{"action" => "complete"} = action} ->
            append_step(state, "complete: #{summary_for(action)}")
            finalize(advance_turn(state), "completed", summary_for(action))

          {:ok, %{"action" => "abort"} = action} ->
            append_step(state, "abort: #{summary_for(action)}")
            finalize(advance_turn(state), "aborted", summary_for(action))

          {:ok, action} ->
            dispatch_and_record(action, state)

          {:error, reason} ->
            finalize(state, "aborted",
              "Action LLM failed to emit a valid action: #{format_error(reason)}")
        end

      {:error, reason} ->
        finalize(state, "aborted",
          "Observation failed: #{format_error(reason)}")
    end
  end

  defp dispatch_and_record(action, state) do
    case dispatch(action, state) do
      {:ok, daemon_result} ->
        url_after = daemon_result["url"] || state.last_url
        append_step(state, step_label(action, true))

        new_state =
          state
          |> push_history(action, true, nil)
          |> advance_turn()
          |> Map.put(:last_url, url_after)
          |> capture_read_result(action, daemon_result)
          |> reset_action_streak()

        loop(new_state)

      {:error, reason} ->
        append_step(state, step_label(action, false) <> " (#{format_error(reason)})")

        new_state =
          state
          |> push_history(action, false, format_error(reason))
          |> advance_turn()
          |> bump_action_streak(action)

        cond do
          new_state.action_streak.count >= AgentSettings.browser_stuck_action_limit() ->
            finalize(new_state, "stuck_action",
              "Same action failed #{new_state.action_streak.count} consecutive turns; abandoning.")

          true ->
            loop(new_state)
        end
    end
  end

  # ── dispatch ──────────────────────────────────────────────────────────────

  # Translate Navigator-emitted verbs into daemon commands. Verb names
  # map 1:1 to daemon commands except `goto` → `navigate` (where we
  # also inject `wait_until` / `timeout` from settings).
  defp dispatch(%{"action" => verb} = action, state) do
    args = effective_args(action)
    timeout = AgentSettings.browser_action_timeout_ms()

    case verb do
      "click" ->
        case fetch_index(args) do
          {:ok, idx} ->
            DaemonClient.call("click",
              %{index: idx, button: args["button"] || "left", timeout: timeout},
              daemon_ctx(state))

          {:error, msg} ->
            {:error, {:daemon_error, %{type: "invalid_args", message: msg}}}
        end

      "type" ->
        case fetch_index(args) do
          {:ok, idx} ->
            DaemonClient.call("type",
              %{
                index: idx,
                text: args["text"] || "",
                submit: args["submit"] == true,
                timeout: timeout
              },
              daemon_ctx(state))

          {:error, msg} ->
            {:error, {:daemon_error, %{type: "invalid_args", message: msg}}}
        end

      "key" ->
        DaemonClient.call("key", %{name: args["name"]}, daemon_ctx(state))

      "scroll_by" ->
        DaemonClient.call("scroll_by",
          %{dx: args["dx"] || 0, dy: args["dy"] || 0},
          daemon_ctx(state))

      "goto" ->
        DaemonClient.call("navigate", navigate_args(args["url"]),
          daemon_ctx(state))

      "back" ->
        DaemonClient.call("back", %{}, daemon_ctx(state))

      "extract_text" ->
        daemon_args =
          case args["index"] do
            n when is_integer(n) and n >= 1 -> %{index: n}
            _ -> %{}
          end

        DaemonClient.call("extract_text", daemon_args, daemon_ctx(state))

      "wait" ->
        DaemonClient.call("wait", %{ms: args["ms"] || 0}, daemon_ctx(state))

      other ->
        {:error, {:daemon_error,
          %{type: "unknown_verb",
            message: "unknown action verb: #{inspect(other)}"}}}
    end
  end

  defp fetch_index(args) do
    case args["index"] do
      n when is_integer(n) and n >= 1 -> {:ok, n}
      # Some models occasionally wrap the integer in a single-element
      # list (`"index": [7]`). Unpack rather than reject — the
      # intent is unambiguous and a hard reject would cost a turn.
      [n] when is_integer(n) and n >= 1 -> {:ok, n}
      _ -> {:error, "missing or invalid `index` (positive integer required)"}
    end
  end

  # Build the effective args map, accommodating models that emit
  # action verbs with the index / text / etc. at the TOP LEVEL of the
  # JSON object rather than nested inside `args`. The schema says
  # `{ "action": ..., "args": {...}, "reason": ... }` but some models
  # flatten this to `{ "action": ..., "index": N, "reason": ... }`.
  # Both are unambiguous — accept either. Liberal in what we read
  # rather than burning turns on `invalid_args` failures.
  defp effective_args(%{"action" => _} = action) do
    nested = action["args"] || %{}

    top =
      action
      |> Map.drop(["action", "args", "reason"])

    # Nested wins on key conflict — when the model bothered to write
    # `args: {...}`, that's the more deliberate placement.
    Map.merge(top, nested)
  end

  defp effective_args(_), do: %{}

  # Shared navigate-args builder for both the initial `Browser.Loop.run/4`
  # nav and the model-emitted `goto` verb.
  defp navigate_args(url) do
    %{
      url: url,
      wait_until: AgentSettings.browser_navigate_wait_until(),
      timeout: AgentSettings.browser_navigate_timeout_ms()
    }
  end

  # ── observation ───────────────────────────────────────────────────────────

  defp build_observation(state, snap) do
    vp = snap["viewport"] || %{}
    vw = vp["w"] || (state.client_viewport && state.client_viewport.w) || 0
    vh = vp["h"] || (state.client_viewport && state.client_viewport.h) || 0
    vclass = viewport_class(state.client_viewport)
    elements = snap["elements"] || []

    blocks =
      [
        "URL:      #{snap["url"] || state.last_url || ""}",
        "TITLE:    #{snap["title"] || state.last_title || "(none)"}",
        "VIEWPORT: #{vw}×#{vh} (#{vclass})",
        "",
        elements_block(elements),
        "",
        recent_actions_block(state)
      ] ++
        extracted_text_section(state) ++
        [
          "",
          "Goal:        #{state.goal}",
          "Constraints: #{empty_or(state.constraints, "(none)")}",
          "",
          "Emit your next action as JSON:",
          ~s({ "action": "<verb>", "args": {...}, "reason": "<one line>" }),
          ""
        ]

    Enum.join(blocks, "\n")
  end

  defp elements_block([]) do
    "ELEMENTS (visible interactives, target by `index`):\n  (none — page has no clickable elements in the current viewport; try `scroll_by` or `extract_text`)"
  end

  defp elements_block(elements) when is_list(elements) do
    lines =
      elements
      |> Enum.map(&format_element/1)
      |> Enum.join("\n")

    "ELEMENTS (visible interactives, target by `index`):\n" <> lines
  end

  defp format_element(%{"idx" => idx, "tag" => tag} = el) do
    text = el["text"]
    label =
      cond do
        is_binary(text) and text != "" -> inspect(text)
        true -> ""
      end

    # `label` is the daemon's best-effort recovery of an input's
    # human-visible label — `<label for=…>`, wrapping `<label>`,
    # ARIA, or nearest preceding sibling text. For inputs the label
    # is far more useful for disambiguation than the empty `value`,
    # so it leads when present.
    hints =
      [
        if(el["label"], do: "label=" <> inspect(el["label"]), else: nil),
        if(el["role"], do: "role=" <> inspect(el["role"]), else: nil),
        if(el["type"], do: "type=" <> inspect(el["type"]), else: nil),
        if(el["placeholder"], do: "placeholder=" <> inspect(el["placeholder"]), else: nil),
        if(el["value"] && label == "", do: "value=" <> inspect(el["value"]), else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    parts = ["  [#{idx}]", String.pad_trailing(tag, 8)] ++
              Enum.reject([label, hints], &(&1 == ""))

    Enum.join(parts, " ")
  end

  defp format_element(_), do: ""

  defp viewport_class(%{is_mobile: true}), do: "mobile"
  defp viewport_class(%{w: w}) when is_integer(w) and w < 900, do: "tablet"
  defp viewport_class(_), do: "desktop"

  defp recent_actions_block(state) do
    recent = Enum.take(state.history, @recent_actions_window)
    header = "RECENT ACTIONS (last #{@recent_actions_window}):"

    body =
      if recent == [] do
        "  (none)"
      else
        recent
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, i} -> "  T-#{i}  " <> format_history_entry(entry) end)
        |> Enum.join("\n")
      end

    header <> "\n" <> body
  end

  defp format_history_entry(%{action: action, ok?: ok?, error: err}) do
    verb = action["action"]
    args = action["args"] || %{}

    key_arg =
      cond do
        is_integer(args["index"]) ->
          case args["text"] do
            t when is_binary(t) and t != "" -> "(#{args["index"]}, #{inspect(slice(t, 30))})"
            _ -> "(#{args["index"]})"
          end
        is_binary(args["url"]) -> "(" <> inspect(slice(args["url"], 60)) <> ")"
        is_binary(args["name"]) -> "(" <> args["name"] <> ")"
        is_integer(args["dx"]) or is_integer(args["dy"]) ->
          "(dx=#{args["dx"] || 0}, dy=#{args["dy"] || 0})"
        is_integer(args["ms"]) -> "(#{args["ms"]}ms)"
        true -> ""
      end

    # 120-char cap on the failure reason: gives the model enough text
    # to see the error type ("Timeout 3000ms exceeded", "outside
    # viewport", "stale_index") AND act on it (the system prompt
    # routes stale_index → re-grab, action_failed → dismiss overlay).
    # 60 chars trimmed the timeout hint before the model could read it.
    status = if ok?, do: "ok", else: "fail" <> if(err, do: " (#{slice(err, 120)})", else: "")
    "#{verb}#{key_arg} → #{status}"
  end

  defp extracted_text_section(%{last_extract: nil}), do: []

  defp extracted_text_section(%{last_extract: text}) when is_binary(text) do
    cap = AgentSettings.browser_extracted_text_cap()
    body = slice(text, cap)

    [
      "",
      "EXTRACTED_TEXT (from last extract_text — use this content to satisfy the goal, or call `complete` with the relevant slice in `result`):",
      body
    ]
  end

  # ── LLM call ──────────────────────────────────────────────────────────────

  @system_prompt """
  You operate a real web browser on behalf of a human user. They have given you a GOAL. Your only job is to produce a concrete result that satisfies that goal — a piece of information they wanted, a state change they asked for, a transaction advanced to the user's own confirmation point. LOOK at the annotated screenshot — every clickable / typeable element is wrapped in a magenta box with a numeric index inside. Pick an action that targets one of those indices. Stop honestly the moment the goal is met, or once you've established it can't be.

  Each turn you receive:
    - An annotated SCREENSHOT of the current viewport. Magenta boxes mark indexed interactives; the number inside each box is its index.
    - URL / TITLE / VIEWPORT dimensions and class (desktop / tablet / mobile).
    - ELEMENTS: the descriptor list for every indexed interactive (e.g. `[7] button "Accept"`). The index in the list matches the number you see on the screenshot.
    - RECENT ACTIONS: the last few actions you took and their outcomes.
    - EXTRACTED_TEXT: present only when your previous action was `extract_text` — the actual page text the daemon returned.
    - GOAL and CONSTRAINTS from the user.

  You respond with exactly ONE JSON object — nothing else, no code fences. The verb-specific arguments go INSIDE the `args` object as their declared types (integers as integers, strings as strings — not arrays):

  { "action": "<verb>", "args": {...}, "reason": "<one short line>" }

  Concrete shape (the index goes in `args`, as a single integer, NOT at the top level and NOT in a list):

  { "action": "click", "args": { "index": 7 }, "reason": "Open the search panel" }

  Verbs and args:

    click        { "index": <N>, "button"?: "left"|"right"|"middle" }
    type         { "index": <N>, "text": "<string>", "submit"?: true|false }
    key          { "name": "Enter"|"Escape"|"Tab"|"ArrowDown"|... }
    scroll_by    { "dx": <int>, "dy": <int> }    -- +dy = scroll down
    goto         { "url": "https://..." }
    back         { }
    extract_text { "index"?: <N> }               -- defaults to whole body
    wait         { "ms": <0..3000> }
    complete     { "reason": "<one line>", "result": "..." }
    abort        { "reason": "<one line>" }

  OPERATING PRINCIPLE: act on the page the way a focused human user would. Hold the goal in mind, take the next concrete interaction that moves toward it.

    • DISMISS ONLY OVERLAYS THAT VISUALLY COVER YOUR ACTION TARGET. Look at the screenshot: is your target button / input / link clearly visible AND clickable as drawn, or is it covered / dimmed / behind a centered card? Two distinct situations, opposite responses:
      – A centered modal card with the rest of the page dimmed / blurred behind it, OR a sticky banner that overlaps your target button → THAT is a blocking overlay. Find its Accept / Reject / Close / Later / Agree / OK / Continue / Got it / X button in ELEMENTS and click it FIRST. Only after it's gone do you engage the underlying UI.
      – A thin notice ribbon / announcement strip / promo bar at the top or side that does NOT cover the form or content you need → that's decoration. LEAVE IT. The page is fully usable as-is. Don't burn turns clicking "notice" / "announcement" / promo text just because the word "notice" caught your attention; that text is usually a link to an article, not a dismiss control.
      Heuristic: page rest is dimmed → dismiss. Page rest is fully crisp → ignore the strip, proceed with the actual task.

    • TARGET BY INDEX. To act on an element, find its magenta box on the screenshot, read the number, emit the matching `index` from the ELEMENTS list. Never invent coordinates — there are no pixel-based verbs. If an element you need has no magenta box, it isn't currently clickable (offscreen, hidden, or non-interactive) — `scroll_by` to bring it into view, or pick a different path.

    • INDICES ARE PER-TURN. The number labelling a box is valid ONLY for the current screenshot. Every state-mutating action (click / type / scroll / navigate) invalidates the indices; next turn you'll see freshly-numbered boxes. Read the new ELEMENTS list each turn before deciding what to click — the same N typically maps to a different element after the page mutates.

    • CHOOSE READ vs OPERATE based on where the answer lives:
      – Goal satisfied by content already on the current page (describe / summarise / look up something shown on load): `extract_text` once, then `complete` with the relevant slice as `result`. Do not extract twice on the same page.
      – Goal requires data BEHIND a form / search / filter / login (a specific search result, a price for a specific input, an account-specific value): operating the form IS the path. `type` each required field by its index, `click` select-dropdown options visible on the page, then `click` the submit / search / find button. Only AFTER the results render do you read or report them.
      – Multi-step transaction (booking, checkout, sign-up): walk the flow normally and STOP at the final payment / final-submit step. `complete` with the cart / order summary in `result`. The user confirms that final step themselves.

    • TYPE STRAIGHT INTO INPUTS. `type {index, text}` focuses the indexed field, clears it, and types real keystrokes in one shot. Do NOT click first and then type as a separate turn.

    • DATE / TIME / QUANTITY FIELDS ARE OFTEN PICKERS, NOT INPUTS. If you need to set a date, time, quantity, or other selectable value AND the ELEMENTS list shows the field as a `button` / `div role="button"` / non-input element (not an `<input>` you can type into), it's a TRIGGER for a popup widget — typing won't work, the form won't accept free-text input there. The shape is always: (1) `click` the trigger; the page mutates and a calendar grid / time list / number stepper / dropdown menu pops up. (2) The next observation lists the popup's interactives — day cells, time slots, +/- buttons, options — with fresh indices. (3) `click` the cell / option matching the value you want. Don't keep retrying `type` on a non-input; don't burn turns refilling other fields that are already correct. If the goal needs that picker value, work the picker.

    • IF A click / type FAILS, you'll see it in RECENT ACTIONS as `→ fail (...)`. Three error kinds, each demanding a different next move:
      – `stale_index` — the page mutated before your action landed. Just pick from the fresh ELEMENTS list next turn.
      – `action_failed: Timeout ...` (or "outside viewport", "not stable", etc.) — Playwright tried but the element wasn't clickable. Most likely an overlay is intercepting clicks. Dismiss any visible banner / modal / popup FIRST (look up its Accept / Close button in ELEMENTS) before retrying.
      – `not_typeable: <tag> at idx=N cannot receive text input` — you sent `type` to a non-input element (a link, button, or div). Find a real `<input>` or `<textarea>` in ELEMENTS (placeholder hints or `type="text"` markers help) and retry there.

    • NEVER REPEAT THE SAME failed action. If a `{verb, args}` pair failed last turn and the page hasn't changed in a way that would obviously fix it, try a different verb or a different index — repeating it triggers a stuck_action halt.

    • TERMINATE CLEANLY. End the loop the moment the goal is satisfied: `complete` with the concrete answer in `result`. End it honestly if it can't be: `abort` with the specific blocker in `reason`. Don't hand back a vague "I tried, here's what was on the page" — that's not a result.

  Keep `reason` to one short clause. No chain-of-thought, no apologies, no commentary.
  """

  defp ask_action(observation_text, snap, state) do
    model = AgentSettings.navigator_model()
    image_b64 = snap["image_b64"] || ""
    mime = snap["mime"] || "image/jpeg"

    messages = [
      %{"role" => "system", "content" => @system_prompt},
      %{"role" => "user",
        "content" => [
          # OpenAI / Anthropic-compatible multimodal content shape:
          # a list of parts (image + text). The OpenAI adapter passes
          # this through unchanged; the Anthropic adapter normalises
          # to its own image/source schema.
          %{"type" => "image_url",
            "image_url" => %{"url" => "data:#{mime};base64,#{image_b64}"}},
          %{"type" => "text", "text" => observation_text}
        ]}
    ]

    trace_meta = %{
      origin: "browser_loop",
      path: "Browser.Loop.ask_action",
      role: "Navigator",
      phase: "turn#{state.turn}"
    }

    case LLM.call(model, messages, trace: trace_meta) do
      {:ok, text} when is_binary(text) ->
        parse_action(text)

      {:ok, {:tool_calls, _}} ->
        {:error, "Navigator emitted tool_calls instead of a text JSON object"}

      {:error, reason} ->
        {:error, "LLM call failed: #{format_error(reason)}"}
    end
  end

  # Strip code fences + find first balanced `{...}` block, decode it.
  defp parse_action(text) do
    body =
      text
      |> String.trim()
      |> strip_code_fence()

    case extract_json_object(body) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"action" => verb} = action} when is_binary(verb) ->
            {:ok, action}

          {:ok, _other} ->
            {:error, "action JSON missing `action` field: #{slice(body, 200)}"}

          {:error, %Jason.DecodeError{} = e} ->
            {:error, "action JSON malformed at position #{e.position}: #{slice(body, 200)}"}
        end

      :error ->
        {:error, "no JSON object found in Navigator output: #{slice(body, 200)}"}
    end
  end

  defp strip_code_fence(s) do
    case Regex.run(~r/\A```(?:json)?\s*\n(.*?)\n```\z/s, s, capture: :all_but_first) do
      [inner] -> String.trim(inner)
      _ -> s
    end
  end

  defp extract_json_object(s) do
    case :binary.match(s, "{") do
      {start, 1} -> walk_braces(s, start, start + 1, 1, false, false)
      :nomatch -> :error
    end
  end

  defp walk_braces(s, start, pos, depth, in_string, escape) do
    if pos >= byte_size(s) do
      :error
    else
      <<_::binary-size(pos), ch, _::binary>> = s

      cond do
        escape ->
          walk_braces(s, start, pos + 1, depth, in_string, false)

        ch == ?\\ and in_string ->
          walk_braces(s, start, pos + 1, depth, in_string, true)

        ch == ?" ->
          walk_braces(s, start, pos + 1, depth, not in_string, false)

        in_string ->
          walk_braces(s, start, pos + 1, depth, in_string, false)

        ch == ?{ ->
          walk_braces(s, start, pos + 1, depth + 1, in_string, false)

        ch == ?} ->
          new_depth = depth - 1
          if new_depth == 0 do
            {:ok, binary_part(s, start, pos - start + 1)}
          else
            walk_braces(s, start, pos + 1, new_depth, in_string, false)
          end

        true ->
          walk_braces(s, start, pos + 1, depth, in_string, false)
      end
    end
  end

  # ── progress UI ───────────────────────────────────────────────────────────

  defp append_step(state, label) do
    SessionProgress.append_sub_label(state.progress_row_id, label)
    state
  end

  defp step_label(action, ok?) do
    verb = action["action"]
    reason = action["reason"]

    text =
      cond do
        is_binary(reason) and reason != "" -> reason
        true -> "#{verb} #{key_arg_summary(action)}"
      end

    if ok?, do: text, else: "FAIL: " <> text
  end

  defp key_arg_summary(action) do
    args = action["args"] || %{}

    cond do
      is_integer(args["index"]) ->
        case args["text"] do
          t when is_binary(t) and t != "" -> "##{args["index"]} " <> inspect(slice(t, 30))
          _ -> "##{args["index"]}"
        end
      is_binary(args["url"]) -> slice(args["url"], 60)
      is_binary(args["name"]) -> args["name"]
      is_integer(args["dx"]) or is_integer(args["dy"]) ->
        "dx=#{args["dx"] || 0}, dy=#{args["dy"] || 0}"
      true -> ""
    end
  end

  # ── history / streak / extract ────────────────────────────────────────────

  defp push_history(state, action, ok?, error) do
    entry = %{action: action, ok?: ok?, error: error}
    %{state | history: [entry | state.history]}
  end

  defp advance_turn(state) do
    %{state | turn: state.turn + 1}
  end

  defp bump_action_streak(state, action) do
    key = action_key(action)

    count =
      if state.action_streak.prev_key == key do
        state.action_streak.count + 1
      else
        1
      end

    %{state | action_streak: %{prev_key: key, count: count}}
  end

  defp reset_action_streak(state) do
    %{state | action_streak: %{prev_key: nil, count: 0}}
  end

  defp action_key(%{"action" => verb, "args" => args}), do: {verb, args}
  defp action_key(%{"action" => verb}), do: {verb, %{}}
  defp action_key(_), do: nil

  defp capture_read_result(state, %{"action" => "extract_text"}, %{"text" => text})
       when is_binary(text) do
    %{state | last_extract: text}
  end

  defp capture_read_result(state, %{"action" => "extract_text"}, _), do: state

  defp capture_read_result(state, _action, _daemon_result) do
    %{state | last_extract: nil}
  end

  # ── exit / summary ────────────────────────────────────────────────────────

  defp finalize(state, status, summary) do
    Logger.info("[Browser.Loop] exit status=#{status} turns=#{state.turn} url=#{state.last_url}")

    {:ok,
     %{
       status: status,
       turns: state.turn,
       summary: summary,
       url: state.last_url,
       title: state.last_title
     }}
  end

  defp summary_for(%{"args" => %{"result" => result}}) when is_binary(result) and result != "",
    do: result

  defp summary_for(%{"args" => %{"reason" => reason}}) when is_binary(reason) and reason != "",
    do: reason

  defp summary_for(%{"reason" => reason}) when is_binary(reason) and reason != "",
    do: reason

  defp summary_for(_), do: "(no summary)"

  # ── helpers ───────────────────────────────────────────────────────────────

  defp elapsed_ms(state),
    do: System.monotonic_time(:millisecond) - state.start_ms

  defp slice(s, n) when is_binary(s) and is_integer(n) and n > 0 do
    if byte_size(s) > n, do: binary_part(s, 0, n) <> "…", else: s
  end

  defp slice(s, _), do: to_string(s)

  defp empty_or("", default), do: default
  defp empty_or(s, _) when is_binary(s), do: s
  defp empty_or(_, default), do: default

  defp format_error({:daemon_error, %{message: msg}}) when is_binary(msg), do: msg
  defp format_error({:daemon_error, %{type: type}}) when is_binary(type), do: type
  defp format_error(:daemon_unreachable), do: "browser daemon unreachable"
  defp format_error(:rate_limited), do: "LLM rate-limited"
  defp format_error(:attempts_exhausted), do: "LLM call exhausted retry budget"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
