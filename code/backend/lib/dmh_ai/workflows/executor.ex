# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor do
  @moduledoc """
  Deterministic walker of a compiled workflow IR. No LLM in the
  loop except for explicit `llm.compose` / `llm.summarise`
  synthetics — every other step is a `Tools.Catalog.call/3`.

  ## Run lifecycle

      trigger fires
        ─▶ Executor.start_run(workflow_id, version, payload, ctx)
              ─▶ INSERT workflow_run_state (status=running)
              ─▶ loop until terminal:
                    resolve_bindings → dispatch → persist emit
                                                    → advance
              ─▶ status = completed | failed | waiting | timed_out

  `caller_ctx.user_id` is always `workflow.created_by` (the
  immutable owner). A step's optional `act_as_user_id` swaps the
  cred-holder for THAT step only; the dispatcher's permission
  gate re-checks at run-time (defense in depth).

  ## Node kinds

    * `step`    — one Tools.Catalog call; emit captured per
                  `emits` map; advance via `next`.
    * `branch`  — predicate over bindings; route via matching
                  `cases[].next` or `else.next`.
    * `gate`    — open an approval; suspend until decision.
    * `wait`    — open a wait row; suspend until matching event
                  or `timeout_seconds` elapses.
    * `output`  — terminal; write emit to the wrapping task.

  ## Bindings namespace

    * `{{T.<path>}}`              — trigger payload
    * `{{<id>.<field>}}`          — node `<id>`'s emit `<field>`
    * `{{owner.email|user_id|display_name}}` — the workflow owner
    * `{{org.id|name}}`           — the wrapping org
    * `{{now}}` / `{{today}}`     — fresh on every step

  This module is a thin shell over the per-node-kind handlers that
  live under `__MODULE__.{Trigger, Step, StepFailure, StepDispatch,
  Branch, Gate, Wait, Output, Bindings}`. Shell owns the public API
  (`start_run/3` / `resume_run/2`) + the walker dispatch loop.
  """

  alias DmhAi.Workflows
  alias __MODULE__.{Bindings, Branch, Gate, Output, Step, Trigger, Wait}

  require Logger

  # Maximum steps a single run may execute before the executor
  # forcibly aborts. Protects against IR cycles (which shouldn't
  # exist — branches/gates/waits are the only legal back-edges,
  # and wait nodes always suspend) and unbounded fan-out.
  @max_steps 200

  # ─── Public API ────────────────────────────────────────────────────────

  @doc """
  Start a new workflow run. `ctx` carries `:org_id`, `:task_id`.
  Returns `{:ok, run_state}` once the executor halts at a terminal
  node (completed / failed) or suspends (waiting). The caller
  (Poller / invoke_workflow / wf_webhook) treats `:waiting` as
  "leave the run suspended; scheduler will resume on event".
  """
  @spec start_run(String.t(), integer(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def start_run(workflow_id, version, trigger_payload, ctx)
      when is_binary(workflow_id) and is_integer(version)
       and is_map(trigger_payload) and is_map(ctx) do
    org_id = Map.fetch!(ctx, :org_id)

    with {:ok, workflow}   <- fetch_workflow(org_id, workflow_id),
         {:ok, %{ir: ir}}  <- fetch_version(org_id, workflow_id, version),
         {:ok, run_state}  <- Workflows.create_run(%{
                                workflow_id:      workflow_id,
                                workflow_version: version,
                                org_id:           org_id,
                                task_id:          Map.get(ctx, :task_id, "manual"),
                                owner_user_id:    workflow.created_by,
                                trigger_payload:  trigger_payload
                              }) do
      Logger.info("[Executor] start run=#{run_state.id} wf=#{workflow_id} v#{version} owner=#{workflow.created_by}")
      walk(ir, first_node(ir), run_state, 0)
    end
  end

  @doc """
  Resume a run that was suspended at a wait/gate. `resume_payload`
  is what the wait was looking for (approval decision, webhook
  body, etc.). The executor evaluates the predicate, advances to
  the appropriate next node, and continues.
  """
  @spec resume_run(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resume_run(run_id, resume_payload)
      when is_binary(run_id) and is_map(resume_payload) do
    case Workflows.get_run(run_id) do
      nil ->
        {:error, :run_not_found}

      %{status: "completed"} = state ->
        {:ok, state}

      %{status: status} when status not in ["running", "waiting"] ->
        {:error, {:bad_status, status}}

      state ->
        org_id = state.org_id
        case fetch_version(org_id, state.workflow_id, state.workflow_version) do
          {:ok, %{ir: ir}} ->
            current_id = state.current_node
            node       = find_node_by_id(ir, current_id)
            wait       = Workflows.get_wait(run_id, current_id)

            Workflows.delete_wait(run_id, current_id)

            bindings = Bindings.put_emits(state.bindings, current_id, resume_payload)
            state = %{state | bindings: bindings}
            :ok = Workflows.update_run(run_id, %{bindings: bindings})

            # `reauth_pause` waits stem from a step that failed and was
            # held for the user to reconnect / fix. On resume the SAME
            # step retries (not the next one) — the user has done what
            # the failure asked for; we re-run to see if it now passes.
            # Regular waits (gate / wait / webhook) skip to the next
            # node via `find_next_after_wait/3`.
            next =
              case wait do
                %{kind: "reauth_pause"} ->
                  node

                _ ->
                  case Wait.find_next_after_wait(ir, node, resume_payload) do
                    nil -> nil
                    nid -> find_node_by_id(ir, nid)
                  end
              end

            walk(ir, next, state, 0)

          err -> err
        end
    end
  end

  # ─── Walker ────────────────────────────────────────────────────────────

  @doc """
  Drive one step of the walker. Sub-modules call back into this after
  handling their node so the loop continues until a terminal node,
  suspension, or step-limit abort.
  """
  def walk(_ir, nil, state, _step_count) do
    :ok = Workflows.complete_run(state.id, :completed)
    {:ok, Workflows.get_run!(state.id)}
  end

  def walk(_ir, _node, state, n) when n >= @max_steps do
    err = %{error: :step_limit_exceeded, limit: @max_steps}
    :ok = Workflows.complete_run(state.id, :failed, err)
    {:error, err}
  end

  def walk(ir, node, state, n) do
    :ok = Workflows.update_run(state.id, %{current_node: node["id"]})

    # User-paused or cancelled? Halt before the next step. Cancellation
    # is terminal; pause is recoverable via resume_workflow_run.
    case maybe_halt_for_user_signal(state) do
      {:halt, halt_result} ->
        halt_result

      :continue ->
        dispatch_node(ir, node, state, n)
    end
  end

  defp dispatch_node(ir, node, state, n) do
    case node["kind"] || "step" do
      "trigger" -> Trigger.handle_trigger(ir, node, state, n)
      "step"    -> Step.handle_step(ir, node, state, n)
      "branch"  -> Branch.handle_branch(ir, node, state, n)
      "gate"    -> Gate.handle_gate(ir, node, state, n)
      "wait"    -> Wait.handle_wait(ir, node, state, n)
      "output"  -> Output.handle_output(ir, node, state)
      other     ->
        err = %{error: :unknown_node_kind, kind: other, node_id: node["id"]}
        :ok = Workflows.complete_run(state.id, :failed, err)
        {:error, err}
    end
  end

  # Re-read the run row from DB and check pause/cancel flags. The flags
  # are user-set out-of-band via `pause_workflow_run` / `cancel_workflow_run`,
  # so we re-fetch state at every step boundary (not just at start).
  defp maybe_halt_for_user_signal(state) do
    case Workflows.get_run(state.id) do
      nil ->
        :continue

      %{status: "cancelled"} = fresh ->
        Logger.info("[Executor] cancelled run=#{state.id} at node=#{state.current_node || "?"}")
        {:halt, {:ok, fresh}}

      %{paused: true} = fresh ->
        Logger.info("[Executor] paused run=#{state.id} at node=#{state.current_node || "?"}")
        # Don't change status to a new "paused" string — `paused` is an
        # orthogonal flag the executor reads at every step boundary.
        # Status stays at whatever it was (running / waiting). The
        # executor just returns; a subsequent `resume_workflow_run` flips
        # the flag and the runtime drives the executor onward.
        {:halt, {:ok, fresh}}

      _ ->
        :continue
    end
  end

  # ─── Internal helpers exposed to sub-modules ───────────────────────────

  @doc """
  Locate a node in the IR by id. Returns `nil` when the id is `nil`
  or the IR lacks a matching node — every callsite handles `nil` as
  "no next node, walker completes".
  """
  def find_node_by_id(_ir, nil), do: nil

  def find_node_by_id(ir, id) do
    nodes = Map.get(ir, "nodes") || []
    Enum.find(nodes, fn n -> n["id"] == id end)
  end

  @doc """
  Render an arbitrary error value into a shape safe to embed in the
  persisted error envelope. Atoms / binaries / tuples become inspect
  strings; maps pass through untouched.
  """
  def encode_err(e) when is_atom(e) or is_binary(e), do: inspect(e)
  def encode_err(%{} = m),                            do: m
  def encode_err(other),                              do: inspect(other)

  # ─── Shell-private helpers ─────────────────────────────────────────────

  defp fetch_workflow(org_id, workflow_id) do
    case Workflows.get_workflow(org_id, workflow_id) do
      nil -> {:error, :workflow_not_found}
      w   -> {:ok, w}
    end
  end

  defp fetch_version(org_id, workflow_id, version) do
    case Workflows.get_version(org_id, workflow_id, version) do
      nil -> {:error, :version_not_found}
      v   -> {:ok, v}
    end
  end

  # The entry point is always the trigger node. The validator
  # guarantees exactly one exists; if a malformed IR ever sneaks
  # through, fall back to the first node so the run still progresses.
  defp first_node(%{"nodes" => nodes}) when is_list(nodes) do
    Enum.find(nodes, fn n -> n["kind"] == "trigger" end) ||
      List.first(nodes)
  end

  defp first_node(_), do: nil
end
