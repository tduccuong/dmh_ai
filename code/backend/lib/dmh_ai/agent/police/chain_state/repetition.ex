# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Police.ChainState.Repetition do
  @moduledoc """
  Police gates that fire on REPETITION / OVERUSE patterns in the
  in-chain message accumulator:

    * `check_no_duplicate_tool_call/3` — same `(tool, significant arg)`
      already invoked earlier in this chain.
    * `check_repeated_tool_error/3` — same tool returning the IDENTICAL
      error message twice in a row.
    * `check_no_consecutive_web_search/3` — two `web_search`es with
      nothing between them.
    * `check_run_script_probe_budget/3` — per-chain cap on
      `run_script` calls.
    * `consecutive_run_script_advisory/2` — soft educational note
      prepended to a back-to-back `run_script` result.
  """

  require Logger

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Agent.Police.PathSafety

  # ── duplicate tool-call gate ───────────────────────────────────────────

  @doc """
  Per-tool-call gate: reject when the same `(tool_name, significant_arg)`
  combination has already been invoked earlier in THIS chain. Prevents
  the "model re-extracts the same PDF twice" misbehaviour that appears
  on weaker models.

  `prior_messages` is the in-chain message accumulator — a list containing
  every assistant-role message with `tool_calls` emitted earlier in this
  chain (either in a prior turn, OR earlier in the CURRENT batch of
  tool_calls from one LLM response).

  Significance key per tool:

    * `extract_content` → `path` (case-sensitive; Linux FS)
    * `web_search`      → `query` (downcased + trimmed)
    * `run_script`      → `script` normalised (comment lines stripped,
                          whitespace runs collapsed) — catches loops
                          where the model only varies a comment

  Tools outside this list bypass the check (no significance key defined).
  """
  @spec check_no_duplicate_tool_call(String.t(), map(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_no_duplicate_tool_call(name, args, prior_messages)
      when is_binary(name) and is_map(args) and is_list(prior_messages) do
    case significant_key(name, args) do
      nil ->
        :ok

      key ->
        if already_called?(name, key, prior_messages) do
          reason =
            "Error: you already called `#{name}` with the same significant argument " <>
              "(#{describe_key(name)}=#{inspect(key)}) earlier in THIS chain. " <>
              "Duplicate calls aren't useful — the earlier call's result is " <>
              "already in your context as a `role: \"tool\"` message. Either " <>
              "answer the user from the earlier result, or call a DIFFERENT " <>
              "tool to move forward. Do not repeat yourself."

          Logger.warning(
            "[Police] REJECTED duplicate_tool_call_in_chain: tool=#{name} key=#{inspect(key)}"
          )

          DmhAi.SysLog.log(
            "[POLICE] REJECTED duplicate_tool_call_in_chain: tool=#{name} key=#{inspect(key)}"
          )

          {:rejected, {:duplicate_tool_call_in_chain, reason}}
        else
          :ok
        end
    end
  end
  def check_no_duplicate_tool_call(_, _, _), do: :ok

  # Pick the "significant argument" that defines a duplicate. Normalised
  # forms let "Explain X" / "explain x " be treated as the same key.
  defp significant_key("extract_content", args) do
    case args["path"] do
      p when is_binary(p) and p != "" -> String.trim(p)
      _ -> nil
    end
  end

  defp significant_key("web_search", args) do
    case args["query"] do
      q when is_binary(q) ->
        n = q |> String.trim() |> String.downcase()
        if n == "", do: nil, else: n

      _ ->
        nil
    end
  end

  # `run_script` keys on the script text NORMALISED — comment lines (`#`-
  # prefixed) stripped, whitespace runs collapsed to single spaces.
  # Catches the common misbehaviour where a model loops on the same curl
  # / shell command and only varies the leading comment ("# Try again",
  # "# With correct syntax").
  defp significant_key("run_script", args) do
    case args["script"] do
      s when is_binary(s) and s != "" ->
        normalised =
          s
          |> String.split("\n")
          |> Enum.reject(&(&1 |> String.trim() |> String.starts_with?("#")))
          |> Enum.join(" ")
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        if normalised == "", do: nil, else: normalised

      _ ->
        nil
    end
  end

  # Tools where legitimate same-arg repetition is the norm and a
  # dedupe block would be a bug. `request_input` re-prompts the user
  # whenever the prior answer was empty / cancelled; `mk_download_link`
  # republishes the same artifact when the user asks again. Everything
  # else falls through to the generic JSON hash so that repeat tool
  # calls with identical args are caught by default.
  @duplicate_check_whitelist ~w(request_input mk_download_link)

  defp significant_key(name, _args) when name in @duplicate_check_whitelist, do: nil

  # Generic fallback: hash the JSON-encoded args. Any two calls with
  # the same (name, args) pair collide; varied args produce different
  # keys. Catches the runaway `connect_mcp(slug: X) × 3`, repeated
  # identical `inspect_function`, repeated `activate_profile(...)`,
  # repeated `upsert_workflow(<same IR>)`, etc. — without us having
  # to maintain a hand-curated per-tool list.
  defp significant_key(_name, args) when is_map(args) do
    case Jason.encode(args) do
      {:ok, json} ->
        case String.trim(json) do
          "" -> nil
          "{}" -> nil
          j -> :crypto.hash(:sha256, j) |> Base.encode16(case: :lower) |> binary_part(0, 16)
        end

      _ ->
        nil
    end
  end

  defp significant_key(_, _), do: nil

  defp describe_key("extract_content"), do: "path"
  defp describe_key("web_search"),      do: "query"
  defp describe_key("run_script"),      do: "normalized script"
  defp describe_key(_),                 do: "args"

  # Walk the prior messages, extract every assistant-role tool_call's
  # (name, significant_key), return true if any match the current pair.
  defp already_called?(name, key, prior_messages) do
    Enum.any?(prior_messages, fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) do
        Enum.any?(calls, fn c ->
          # Skip calls Police itself rejected upstream. A rejection
          # means the call never ran, so the next attempt with the
          # same args is a retry — not a duplicate.
          rejected? = c["_rejected"] || c[:_rejected] || false

          if rejected? do
            false
          else
            fn_map    = c["function"] || c[:function] || %{}
            call_name = fn_map["name"] || fn_map[:name] || ""
            raw_args  = fn_map["arguments"] || fn_map[:arguments] || %{}
            call_args = if is_binary(raw_args), do: PathSafety.decode_or_empty(raw_args), else: raw_args

            call_name == name and significant_key(call_name, call_args) == key
          end
        end)
      else
        false
      end
    end)
  end

  # ── repeated tool-error loop guard ─────────────────────────────────────

  @doc """
  Detect tool-error loops: same tool returning the same error message
  twice in a row within one chain. Generic — no whitelist, no
  significance keys. Any tool whose runtime / validation produces an
  identical error twice in a row is by definition not making progress;
  Police rejects the SECOND occurrence and the existing rejection
  pipeline (nudge counter + 3-strike circuit breaker) handles
  escalation.

  Inputs:
    * `tool_name`   — the tool that just emitted `error_text`.
    * `error_text`  — the binary content of the tool result message.
                      Caller passes the raw string; Police trims +
                      compares as-is.
    * `prior_messages` — the in-chain accumulator. Police walks back
                         until it finds the previous role="tool" entry
                         whose `name == tool_name` and checks whether
                         its content equals `error_text` after trim.

  Returns `:ok` on first occurrence, `{:rejected, {:repeated_tool_error,
  reason}}` on the immediate repeat.
  """
  @spec check_repeated_tool_error(String.t(), String.t(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_repeated_tool_error(tool_name, error_text, prior_messages)
      when is_binary(tool_name) and is_binary(error_text) and is_list(prior_messages) do
    norm = String.trim(error_text)

    case prior_tool_error(tool_name, prior_messages) do
      ^norm ->
        reason =
          "Error: `#{tool_name}` just returned the IDENTICAL error to its previous " <>
            "call in this chain:\n\n#{ellipsize(norm, 400)}\n\n" <>
            "Retrying with the same shape will give the same error. STOP repeating " <>
            "and instead reply to the user with: (1) what the error actually means " <>
            "in the user's terms, (2) what you'd need from them to proceed " <>
            "(missing input, ambiguity, an external dependency, …), and (3) two " <>
            "or three concrete options they can pick from. Do NOT call `#{tool_name}` " <>
            "again until the user clarifies."

        Logger.warning(
          "[Police] REJECTED repeated_tool_error: tool=#{tool_name} text=#{inspect(String.slice(norm, 0, 120))}"
        )

        DmhAi.SysLog.log(
          "[POLICE] REJECTED repeated_tool_error: tool=#{tool_name}"
        )

        {:rejected, {:repeated_tool_error, reason}}

      _ ->
        :ok
    end
  end

  def check_repeated_tool_error(_, _, _), do: :ok

  # Walk `prior_messages` newest-first; return the trimmed content of
  # the most recent role="tool" message attributed to `tool_name`, or
  # nil if no prior tool-error from this tool exists in this chain.
  defp prior_tool_error(tool_name, messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: "tool", name: ^tool_name, content: content} when is_binary(content) ->
        String.trim(content)

      %{"role" => "tool", "name" => ^tool_name, "content" => content}
      when is_binary(content) ->
        String.trim(content)

      _ ->
        nil
    end)
  end

  defp ellipsize(s, n) when byte_size(s) <= n, do: s
  defp ellipsize(s, n), do: String.slice(s, 0, n) <> "…"

  # ── consecutive web_search ─────────────────────────────────────────────

  @doc """
  Per-tool-call gate: reject a `web_search` call when the immediately-
  preceding tool call in this chain was ALSO `web_search`.

  Rationale: one `web_search` already fans out 2-3 parallel search
  queries in the BE (see `DmhAi.Web.Search.generate_queries`), so a
  second consecutive call is redundant — the model should either answer
  from what it already has OR reach for a DIFFERENT tool
  (`run_script` with a direct API call when the question targets a
  named service, `web_fetch` when it has a specific URL in mind).

  Alternating is fine: `web_search` → `run_script` → `web_search` is
  allowed when each step has a legitimate role. The gate only fires on
  TWO web_searches with nothing between them.
  """
  @spec check_no_consecutive_web_search(String.t(), map(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_no_consecutive_web_search("web_search", _args, prior_messages)
      when is_list(prior_messages) do
    case last_tool_call_name(prior_messages) do
      "web_search" ->
        reason =
          "Error: your immediately-prior tool call was `web_search`, and one " <>
            "`web_search` already runs 2-3 parallel queries in the backend. " <>
            "Calling it again right now is wasted effort.\n\n" <>
            "The correct research loop is:\n" <>
            "  1. DIGEST what the first `web_search` already returned — read " <>
            "the snippets, identify names/URLs/terms that emerged.\n" <>
            "  2. DIG DEEPER with a DIFFERENT tool on those findings: " <>
            "`web_fetch` a specific URL the snippets mentioned; `run_script` " <>
            "with `curl`/`jq` against a named service's API; `extract_content` " <>
            "on a document you pulled down.\n" <>
            "  3. Once you have concrete findings, THEN — and only if a gap " <>
            "genuinely remains — consider another `web_search` with a query " <>
            "refined by what you just learned."

        Logger.warning("[Police] REJECTED consecutive_web_search")
        DmhAi.SysLog.log("[POLICE] REJECTED consecutive_web_search")
        {:rejected, {:consecutive_web_search, reason}}

      _ ->
        :ok
    end
  end
  def check_no_consecutive_web_search(_, _, _), do: :ok

  # ── run_script probe budget + consecutive advisory ─────────────────────

  @doc """
  Per-tool-call gate: cap `run_script` at `AgentSettings.run_script_probe_budget()`
  per chain (default 5). The (N+1)th `run_script` is rejected with a
  nudge that teaches the model to either compose the rest into ONE more
  script OR end the chain by asking the user the specific question
  probes can't answer.

  Counts ALL `run_script` calls in `prior_messages`, not just consecutive
  ones — once the model is on a probing trajectory, mixing in
  `web_fetch` / `read_file` / etc. doesn't reset the count.

  Returns `:ok` or `{:rejected, {:run_script_probe_budget, reason}}`.
  """
  @spec check_run_script_probe_budget(String.t(), map(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_run_script_probe_budget("run_script", _args, prior_messages)
      when is_list(prior_messages) do
    budget = AgentSettings.run_script_probe_budget()
    count  = count_run_script_calls(prior_messages)

    if count >= budget do
      reason =
        "Error: you've probed enough — #{count} `run_script` call#{if count == 1, do: "", else: "s"} " <>
          "already done on this chain. You've got ONLY one more chance: either combine everything " <>
          "you still want to do into ONE single script (chain values with bash variables — " <>
          "`X=$(curl ...); Y=$(echo \"$X\" | jq ...); curl ... -d \"$Y\"`), OR ask the user the " <>
          "specific question your probes can't answer (which scope to widen, which alternative " <>
          "to accept, which existing field to use). After that, no more probing — text only."

      Logger.warning("[Police] REJECTED run_script_probe_budget: chain count=#{count}")
      DmhAi.SysLog.log("[POLICE] REJECTED run_script_probe_budget: chain count=#{count}")
      {:rejected, {:run_script_probe_budget, reason}}
    else
      :ok
    end
  end

  def check_run_script_probe_budget(_, _, _), do: :ok

  @doc """
  Soft post-execution nudge: when the assistant fires `run_script`
  back-to-back with the previous tool call also being `run_script`,
  return an educational note that the runtime prepends to the tool
  result. The script still runs and the model still gets its output
  — the note teaches it what a proper `run_script` looks like and
  how to recognise two distinct anti-patterns it might be falling
  into.

  Returns `nil` (no nudge) or a binary advisory the caller prepends
  to the tool result content.
  """
  @spec consecutive_run_script_advisory(String.t(), [map()]) :: String.t() | nil
  def consecutive_run_script_advisory("run_script", prior_messages)
      when is_list(prior_messages) do
    case last_tool_call_name(prior_messages) do
      "run_script" ->
        prior_count = count_run_script_calls(prior_messages)
        budget      = AgentSettings.run_script_probe_budget()

        if rem(prior_count, 2) != 1 do
          nil
        else
          Logger.info("[Police] NUDGE consecutive_run_script count=#{prior_count + 1}/#{budget}")
          DmhAi.SysLog.log("[POLICE] NUDGE consecutive_run_script count=#{prior_count + 1}/#{budget}")

          "[⚠ RUNTIME WARNING — Consecutive `run_script`s used. The next-after-cap is REJECTED.]\n\n" <>
          "Before probing again:\n\n" <>
          "  1. SCAN your context FIRST. Re-read prior tool results, the user's " <>
          "original ask, any docs you fetched. Most \"let me verify X\" is " <>
          "already answered above. Re-probing wastes turns — the user is " <>
          "waiting on the ANSWER, not on you re-checking known state.\n\n" <>
          "  2. You MUST COMPOSE. If you have enough to do the full operation " <>
          "in ONE multi-step script (bash-variables to chain values), stop " <>
          "probing and emit it now. Probe-then-execute should be 2 turns, not 5.\n\n" <>
          "  3. Previous script FAILED? Re-PLAN, don't re-PROBE the same shape. " <>
          "A wrong assumption + retry = same wrong answer.\n\n"
        end

      _ ->
        nil
    end
  end

  def consecutive_run_script_advisory(_, _), do: nil

  # Count assistant tool_calls named "run_script" across the prior-messages
  # accumulator. Both atom-key and string-key shapes accepted (the chain
  # loop builds atom-key maps; LLM responses replayed from history use
  # string keys).
  defp count_run_script_calls(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: "assistant", tool_calls: tcs} when is_list(tcs)         -> tcs
      %{"role" => "assistant", "tool_calls" => tcs} when is_list(tcs) -> tcs
      _ -> []
    end)
    |> Enum.count(fn tc ->
      case tc do
        %{function: %{name: "run_script"}}                  -> true
        %{"function" => %{"name" => "run_script"}}          -> true
        _                                                    -> false
      end
    end)
  end

  # Walk `prior_messages` newest-to-oldest, find the last assistant-role
  # message that carries a non-empty `tool_calls` list, return the name
  # of its LAST tool_call.
  defp last_tool_call_name(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) and calls != [] do
        # Skip Police-rejected calls — they never actually ran, so
        # they shouldn't count as "the prior call" for chaining
        # checks like consecutive_web_search.
        live_calls = Enum.reject(calls, &(&1["_rejected"] || &1[:_rejected] || false))

        case List.last(live_calls) do
          nil -> nil
          last_call ->
            fn_map = last_call["function"] || last_call[:function] || %{}
            fn_map["name"] || fn_map[:name]
        end
      else
        nil
      end
    end)
  end
end
