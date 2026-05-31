# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Police.ChainState.Phantom do
  @moduledoc """
  Police gates that judge whether the chain's WRITES landed:

    * `check_no_phantom_outcome/2` — every attempted outcome-write
      errored; success-implying prose now would lie.
    * `write_class?/1` + `outcome_write?/1` — classify a tool as a
      write (`write_class: :write` in its manifest), and the
      outcome-tally subset (excludes `outcome_write: false` setup
      writes like `connect_mcp`).
    * `check_write_failure_budget/3` — cap on consecutive write-class
      failures in one chain.
    * `check_workflow_build_continuity/2` — once `upsert_workflow`
      starts but hasn't saved, block connector dispatches that would
      run the side-effect for real instead of baking it into the IR.
    * `check_fresh_attachments_read/2` + `extract_fresh_attachment_paths/1`
      — every `📎 [newly attached]` path in the current user message
      must be passed to `extract_content` during this turn.
  """

  require Logger

  alias DmhAi.Agent.Police.PathSafety
  alias DmhAi.Tools.Catalog

  # ── phantom-outcome guard ──────────────────────────────────────────────

  @doc """
  Structural guard against PHANTOM OUTCOMES. No language semantics
  — works for any final-text language.

  Reads the chain's OUTCOME tally — `outcome_write?/1` tools that
  actually ran, counted into ctx as they execute. A chain that
  attempted one or more outcome-writes AND saw EVERY one of them
  error is not allowed to end with a final-text turn: the prose
  would imply success while no requested side effect landed. The
  model must retry the failing call or surface the blocker via
  `request_input` / explicit failure.

  Setup/connection writes (`outcome_write: false`, e.g. connect_mcp)
  are NOT in this tally — an incidental connection success must not
  count as "real work happened" and mask a failed `upsert_workflow`.

  Read-only chains (`attempts == 0`) and chains where at least one
  outcome-write landed (`failures < attempts`) pass through. Every
  outcome-write errored → `{:rejected, {:phantom_outcome, reason}}`.
  """
  @spec check_no_phantom_outcome(non_neg_integer(), non_neg_integer()) ::
          :ok | {:rejected, {:phantom_outcome, String.t()}}
  def check_no_phantom_outcome(outcome_attempts, outcome_failures)
      when is_integer(outcome_attempts) and is_integer(outcome_failures) do
    cond do
      outcome_attempts == 0 ->
        # no outcome-write attempted — nothing to falsely claim
        :ok

      outcome_failures < outcome_attempts ->
        # at least one outcome-write landed — real work happened
        :ok

      true ->
        # every attempted outcome-write errored
        reason = phantom_outcome_reason(outcome_attempts)
        Logger.warning("[Police] REJECTED phantom_outcome: attempts=#{outcome_attempts} all errored")
        DmhAi.SysLog.log("[POLICE] REJECTED phantom_outcome: #{outcome_attempts} outcome-writes, all errored")
        {:rejected, {:phantom_outcome, reason}}
    end
  end

  def check_no_phantom_outcome(_, _), do: :ok

  @doc """
  True if `tool_name`'s manifest declares `write_class: :write`.
  Public so the chain loop can tally write attempts / failures into
  ctx counters as they happen — these feed the write-failure BUDGET
  (instead of re-scanning message bodies, which the rolling
  tool-result flush rewrites to a success-looking placeholder).
  """
  @spec write_class?(String.t() | nil) :: boolean()
  def write_class?(nil), do: false

  def write_class?(tool_name) when is_binary(tool_name) do
    case Catalog.lookup(tool_name) do
      {:ok, %{write_class: :write}} -> true
      _                              -> false
    end
  end

  @doc """
  True if a successful call to `tool_name` represents a user-requested
  OUTCOME — the side effect the chain's eventual prose would claim
  happened. This is the subset of write-class tools that the
  phantom-outcome guard tallies.

  A write-class tool opts OUT by declaring `outcome_write: false` in
  its manifest (e.g. `connect_mcp` — establishing a connection is
  setup plumbing, not the outcome). Excluding such tools stops an
  incidental success (a connection landing) from masking a chain
  whose real action (a failed `upsert_workflow`) never succeeded.
  """
  @spec outcome_write?(String.t() | nil) :: boolean()
  def outcome_write?(nil), do: false

  def outcome_write?(tool_name) when is_binary(tool_name) do
    case Catalog.lookup(tool_name) do
      {:ok, %{write_class: :write} = m} -> Map.get(m, :outcome_write, true)
      _                                  -> false
    end
  end

  defp phantom_outcome_reason(attempted) do
    "This chain attempted #{attempted} state-changing call(s) and every one errored. " <>
      "A final-text turn now would imply success, but nothing landed. Pick the remedy that matches WHY they failed: " <>
      "(1) a fixable mistake in the call — a bad or missing argument, a malformed shape, the error names it: correct it and re-emit. " <>
      "(2) a value only the user can supply is missing: `request_input` for THAT specific value. " <>
      "(3) no available tool or function can perform the action at all: reply in plain text that names the missing capability and the concrete options — a different connector, a manual route, or proceeding without that part. " <>
      "`request_input` fits case 2 only; a form cannot supply a capability the deployment lacks, so for case 3 state what is missing rather than asking the user how to proceed. " <>
      "Success-implying prose while every call failed is not allowed."
  end

  # ── write-failure budget ───────────────────────────────────────────────

  @doc """
  Cap on consecutive write-class failures in one chain. Counts
  every prior write attempt in `chain_tail` whose result was an
  error; when that count reaches the per-chain budget the
  dispatcher REJECTS the next write attempt — forcing the model
  to either escalate to the user (via `request_input` / explicit
  blocker text) or end the chain.

  Only gates write-class tool calls; read-only probes always pass.
  The check uses `Tools.Catalog.lookup/1` to read each prior
  tool's `write_class`, so the budget is language-agnostic and
  applies uniformly across built-ins + connector verbs.

  Catches the runaway shape where the model keeps emitting
  upsert_workflow / arm_workflow / *.send / *.create with
  varying-but-broken args, each rejected with a DIFFERENT error
  (so the IDENTICAL-error check doesn't fire). The budget is the
  structural backstop.
  """
  @spec check_write_failure_budget(String.t(), non_neg_integer(), pos_integer()) ::
          :ok | {:rejected, {:write_failure_budget, String.t()}}
  def check_write_failure_budget(tool_name, failures_so_far, budget)
      when is_binary(tool_name) and is_integer(failures_so_far) and is_integer(budget) and budget > 0 do
    if write_class?(tool_name) and failures_so_far >= budget do
      reason = write_failure_budget_reason(failures_so_far, budget)

      Logger.warning(
        "[Police] REJECTED write_failure_budget: tool=#{tool_name} failed=#{failures_so_far} budget=#{budget}"
      )

      DmhAi.SysLog.log(
        "[POLICE] REJECTED write_failure_budget: failed=#{failures_so_far} budget=#{budget}"
      )

      {:rejected, {:write_failure_budget, reason}}
    else
      :ok
    end
  end

  def check_write_failure_budget(_, _, _), do: :ok

  defp write_failure_budget_reason(failed, budget) do
    "This chain has accumulated #{failed} failed write-tool attempt(s) (budget per chain is #{budget}). " <>
      "Stop calling write tools. Reply to the user now with: (1) a plain-language summary of what " <>
      "failed and why, (2) the specific input you'd need from them to unblock, and (3) two or three " <>
      "concrete options. If the connector simply does not expose what the user wants, say so plainly — " <>
      "the user can re-route rather than have you keep guessing."
  end

  # ── workflow-build continuity ──────────────────────────────────────────

  @doc """
  Workflow-build continuity gate. When the model has attempted
  `upsert_workflow` earlier in the chain AND the most recent attempt
  did NOT successfully save, block any external connector tool call
  until the workflow lands.

  Background: a `request_input` issued during workflow compile is a
  pause to gather a VALUE for the IR, not a green light to run the
  underlying action. Smaller models occasionally lose the build
  context across the pause boundary and dispatch the connector
  function directly with the value the user supplied — producing a
  real side-effect (a deal, a contact, an email) instead of a saved
  workflow. This gate is the safety net for that class of failure.

  Skips when:
    * The tool isn't a connector function (`<slug>.<bare>` where
      `<slug>` is registered with `Connectors.Registry`).
    * No `upsert_workflow` attempt is recorded in `prior_messages`.
    * The most recent `upsert_workflow` tool result parses as a
      success envelope (`{name, version, url}`) — the workflow IS
      saved and the model is free to dispatch normally.
  """
  @spec check_workflow_build_continuity(String.t(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_workflow_build_continuity(name, prior_messages)
      when is_binary(name) and is_list(prior_messages) do
    if connector_function?(name) and workflow_build_pending?(prior_messages) do
      reason =
        "Error: you started a workflow build (called `upsert_workflow` earlier in this " <>
          "chain) but it hasn't saved yet. Calling `#{name}` directly would EXECUTE " <>
          "the operation in real life (create a deal, send an email, …) — not what the " <>
          "user asked for. The user asked for a workflow. Bake any new value the user " <>
          "just supplied into the IR (as a literal arg, or as a new trigger input the " <>
          "user supplies each run) and re-call `upsert_workflow`."

      Logger.warning(
        "[Police] REJECTED workflow_build_continuity: tool=#{name}"
      )

      DmhAi.SysLog.log(
        "[POLICE] REJECTED workflow_build_continuity: tool=#{name}"
      )

      {:rejected, {:workflow_build_continuity, reason}}
    else
      :ok
    end
  end

  def check_workflow_build_continuity(_, _), do: :ok

  defp connector_function?(name) do
    case String.split(name, ".", parts: 2) do
      [slug, _bare] when slug != "" ->
        not is_nil(DmhAi.Connectors.Registry.module_for_slug(slug))

      _ ->
        false
    end
  end

  # True when there's an `upsert_workflow` call in the recent
  # history AND the most-recent tool result for it wasn't a success.
  # "Success" is a tool message whose body decodes to a map
  # containing `name`, `version`, and `url` — the shape
  # `upsert_workflow` returns on a clean save.
  defp workflow_build_pending?(prior_messages) do
    prior_messages
    |> Enum.reverse()
    |> Enum.find_value(false, fn msg ->
      role    = Map.get(msg, :role)    || Map.get(msg, "role")
      name    = Map.get(msg, :name)    || Map.get(msg, "name")
      content = Map.get(msg, :content) || Map.get(msg, "content")

      if role == "tool" and name == "upsert_workflow" and is_binary(content) do
        {:found, content}
      else
        nil
      end
    end)
    |> case do
      {:found, content} -> not workflow_save_succeeded?(content)
      _ -> false
    end
  end

  defp workflow_save_succeeded?(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"name" => _, "version" => _, "url" => _}} -> true
      _ -> false
    end
  end

  defp workflow_save_succeeded?(_), do: false

  # ── fresh-attachment enforcement ───────────────────────────────────────

  @doc """
  Enforce that every `📎 ` path in the current turn's user message was
  passed to `extract_content` during this turn. Catches the model-
  compliance failure where the model acknowledges an attachment in
  prose ("I see the PDF you attached…") but never reads it — leaving
  it with no actual content to answer from.

  `fresh_paths` — the list of workspace paths the context builder
  injected the `[newly attached]` marker on for this turn (i.e. the
  `📎 ` paths from the last user message).

  `in_turn_messages` — the messages list accumulated inside
  `session_chain_loop` across tool rounds. Every assistant-role message
  with `tool_calls` is scanned; calls whose name is `"extract_content"`
  contribute their `path` argument to the "read" set.

  Returns `:ok` if every fresh path was read. Otherwise returns a
  rejection message listing the missed paths so the session loop can
  nudge the model to retry.
  """
  @spec check_fresh_attachments_read([String.t()], [map()]) :: :ok | {:rejected, {atom(), String.t()}}
  def check_fresh_attachments_read([], _messages), do: :ok
  def check_fresh_attachments_read(fresh_paths, messages) when is_list(fresh_paths) do
    read_paths = collect_extracted_paths(messages)
    missed     = Enum.reject(fresh_paths, &(&1 in read_paths))

    if missed == [] do
      :ok
    else
      joined = Enum.map_join(missed, "\n", fn p -> "  - `#{p}`" end)
      reason =
        "Error: you have `[newly attached]` attachments in the current user " <>
          "message that you didn't read this turn:\n#{joined}\n" <>
          "You must call `extract_content` once per attachment, passing the " <>
          "workspace path shown above — the user re-attached them because " <>
          "they want another look. Retry the turn: call `extract_content` " <>
          "per attachment, then produce your final answer."

      Logger.warning("[Police] REJECTED fresh_attachments_unread: missed=#{inspect(missed)}")
      DmhAi.SysLog.log("[POLICE] REJECTED fresh_attachments_unread: missed=#{inspect(missed)}")
      {:rejected, {:fresh_attachments_unread, reason}}
    end
  end
  def check_fresh_attachments_read(_, _), do: :ok

  @doc """
  Pull the set of `📎 [newly attached] <path>` paths from the last
  user-role message in a message array. Used at turn start to snapshot
  the "must be read this turn" set for
  `check_fresh_attachments_read/2`.
  """
  @spec extract_fresh_attachment_paths([map()]) :: [String.t()]
  def extract_fresh_attachment_paths(messages) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> (m[:role] || m["role"]) == "user" end)

    case last_user do
      nil -> []
      msg ->
        content = msg[:content] || msg["content"] || ""

        ~r/📎\s+\[newly attached\]\s+(\S+)/u
        |> Regex.scan(content, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&String.trim/1)
    end
  end

  # Scan the turn's message accumulator for `extract_content` tool_calls
  # and return the set of `path` argument values the model passed.
  defp collect_extracted_paths(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) do
        Enum.flat_map(calls, fn call ->
          name = get_in(call, ["function", "name"]) || ""
          args = get_in(call, ["function", "arguments"]) || %{}
          args = if is_binary(args), do: PathSafety.decode_or_empty(args), else: args

          if name == "extract_content" and is_binary(args["path"]) do
            [args["path"]]
          else
            []
          end
        end)
      else
        []
      end
    end)
    |> MapSet.new()
    |> MapSet.to_list()
  end
end
