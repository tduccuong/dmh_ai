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
  """

  alias DmhAi.{Workflows, Repo}
  alias DmhAi.Tools.Catalog
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  # Maximum steps a single run may execute before the executor
  # forcibly aborts. Protects against IR cycles (which shouldn't
  # exist — branches/gates/waits are the only legal back-edges,
  # and wait nodes always suspend) and unbounded fan-out.
  @max_steps 200

  @synthetic_names ~w(llm.compose llm.summarise builtin.compute builtin.coalesce)

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

            bindings = put_emits(state.bindings, current_id, resume_payload)
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
                  case find_next_after_wait(ir, node, resume_payload) do
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

  defp walk(_ir, nil, state, _step_count) do
    :ok = Workflows.complete_run(state.id, :completed)
    {:ok, Workflows.get_run!(state.id)}
  end

  defp walk(_ir, _node, state, n) when n >= @max_steps do
    err = %{error: :step_limit_exceeded, limit: @max_steps}
    :ok = Workflows.complete_run(state.id, :failed, err)
    {:error, err}
  end

  defp walk(ir, node, state, n) do
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
      "trigger" -> handle_trigger(ir, node, state, n)
      "step"    -> handle_step(ir, node, state, n)
      "branch"  -> handle_branch(ir, node, state, n)
      "gate"    -> handle_gate(ir, node, state, n)
      "wait"    -> handle_wait(ir, node, state, n)
      "output"  -> handle_output(ir, node, state)
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

  # ── trigger ──────────────────────────────────────────────────────────
  # The trigger node behaves differently per `trigger_kind`:
  #
  #   * `manual`   — `state.bindings["trigger"]` is the invoke_workflow
  #                  caller's payload. Pass through to `next`; downstream
  #                  refs use `{{T.<field>}}` to bind against it.
  #
  #   * `poll` / `schedule`
  #                — execute the trigger's `connector_function` with
  #                  `connector_args` and bind the result as node 0's
  #                  emits. Same shape an autonomous poller fire would
  #                  produce, run synchronously inside the executor. A
  #                  manual `invoke_workflow` against a polled workflow
  #                  ends up running ONE synthetic poll cycle and the
  #                  rest of the IR — this is "test the workflow with
  #                  current data" from the user's perspective.
  #
  #   * `webhook`  — `state.bindings["trigger"]` is the synthetic
  #                  event payload supplied by the invoke caller. Bind
  #                  it as node 0's emits so `{{0.<field>}}` refs
  #                  resolve the same way they would for an
  #                  autonomous webhook fire.
  defp handle_trigger(ir, node, state, n) do
    case Map.get(node, "trigger_kind", "manual") do
      "manual" ->
        next = find_node_by_id(ir, node["next"])
        walk(ir, next, state, n + 1)

      kind when kind in ["poll", "schedule"] ->
        run_polled_trigger(ir, node, state, n)

      "webhook" ->
        run_webhook_trigger(ir, node, state, n)

      other ->
        err = %{
          error:        :unknown_trigger_kind,
          trigger_kind: other,
          node_id:      node["id"],
          hint:         "trigger_kind must be one of: manual, poll, schedule, webhook"
        }
        :ok = Workflows.complete_run(state.id, :failed, err)
        {:error, err}
    end
  end

  defp run_polled_trigger(ir, node, state, n) do
    fn_name = node["connector_function"]
    args    = resolve_args(node["connector_args"] || %{}, state)

    if not is_binary(fn_name) or fn_name == "" do
      err = %{
        error:   :trigger_misconfigured,
        node_id: node["id"],
        hint:    "trigger_kind=#{node["trigger_kind"]} requires `connector_function` (the function the runtime polls/schedules)"
      }
      :ok = Workflows.complete_run(state.id, :failed, err)
      {:error, err}
    else
      step_id = Workflows.open_step(state.id, node["id"],
        %{function: fn_name, args: args, trigger_kind: node["trigger_kind"]})

      case dispatch_step(fn_name, args, node, state) do
        {:ok, result} ->
          emit         = extract_emits(node, result)
          Workflows.close_step(step_id, :completed, output: emit)
          new_bindings = put_emits(state.bindings, node["id"], emit)
          :ok          = Workflows.update_run(state.id, %{bindings: new_bindings})
          next         = find_node_by_id(ir, node["next"])
          walk(ir, next, %{state | bindings: new_bindings}, n + 1)

        {:error, e} ->
          err = %{
            error:    :trigger_failed,
            node_id:  node["id"],
            function: fn_name,
            detail:   encode_err(e)
          }
          Workflows.close_step(step_id, :failed, error: err)
          :ok = Workflows.complete_run(state.id, :failed, err)
          {:error, err}
      end
    end
  end

  defp run_webhook_trigger(ir, node, state, n) do
    payload = state.bindings["trigger"] || state.bindings[:trigger] || %{}
    step_id = Workflows.open_step(state.id, node["id"],
      %{trigger_kind: node["trigger_kind"], payload: payload})

    emit    = extract_emits(node, payload)
    Workflows.close_step(step_id, :completed, output: emit)
    new_bindings = put_emits(state.bindings, node["id"], emit)
    :ok = Workflows.update_run(state.id, %{bindings: new_bindings})
    next = find_node_by_id(ir, node["next"])
    walk(ir, next, %{state | bindings: new_bindings}, n + 1)
  end

  # ── step ─────────────────────────────────────────────────────────────

  defp handle_step(ir, node, state, n) do
    fn_name = node["function"]
    args    = resolve_args(node["args"] || %{}, state)

    case detect_index_miss(args) do
      {:miss, ref_label, idx} ->
        # Surface an out-of-range array index in the ARG path as a
        # structured `:lookup_miss` failure BEFORE calling the vendor.
        # Classic case: an upstream `<vendor>.<find>` returned an empty
        # list, the downstream consumer wrote `{{N.<list>[0].<field>}}`,
        # and without this check we'd silently pass `""` (or
        # `{:index_miss, _}`) to the vendor's API. The IR's
        # `on_failure[:lookup_miss]` then decides whether to pause for
        # operator intervention or take a recovery branch — same
        # machinery as other classes.
        sanitised_args = scrub_index_miss(args)

        step_id = Workflows.open_step(state.id, node["id"],
          %{function: fn_name, args: sanitised_args})

        err = build_lookup_miss_err(ir, node, state, ref_label, idx)
        handle_step_failure(ir, node, state, step_id, fn_name, err, n)

      :ok ->
        step_id = Workflows.open_step(state.id, node["id"],
          %{function: fn_name, args: args})

        case dispatch_step(fn_name, args, node, state) do
          {:ok, result} ->
            emit = extract_emits(node, result)
            Workflows.close_step(step_id, :completed, output: emit)
            new_bindings = put_emits(state.bindings, node["id"], emit)
            :ok = Workflows.update_run(state.id, %{bindings: new_bindings})
            next = find_node_by_id(ir, node["next"])
            walk(ir, next, %{state | bindings: new_bindings}, n + 1)

          {:error, e} ->
            handle_step_failure(ir, node, state, step_id, fn_name, e, n)
        end
    end
  end

  # Build the `:lookup_miss` error envelope with enough upstream
  # context for the assistant to write an accurate user-facing reply.
  # Specifically: the failed arg name, the raw `{{…}}` binding that
  # resolved to empty, and the upstream step's function name + what
  # it was queried with. Without this, the model has to guess which
  # email / id was used and may quote the wrong value.
  defp build_lookup_miss_err(ir, node, state, ref_label, idx) do
    raw_binding = lookup_raw_binding(node["args"] || %{}, ref_label)
    upstream    = trace_upstream(ir, state, raw_binding)

    %{
      error:    "lookup_miss",
      ref:      ref_label,
      index:    idx,
      binding:  raw_binding,
      upstream: upstream,
      message:  compose_lookup_miss_message(ref_label, idx, upstream)
    }
  end

  defp compose_lookup_miss_message(ref_label, idx, %{function: fn_name, input: input})
       when is_binary(fn_name) and is_map(input) do
    queried = input |> Map.take(["query", "q", "email", "search"]) |> Enum.to_list()
    queried_str =
      case queried do
        [{k, v}] -> " (queried with #{k}=`#{inspect(v)}`)"
        _        -> ""
      end

    "arg `#{ref_label}` came up empty — upstream step `#{fn_name}` returned " <>
      "no entry at index #{idx}#{queried_str}. To resolve, either ensure the " <>
      "upstream lookup produces a match, or update the workflow."
  end

  defp compose_lookup_miss_message(ref_label, idx, _),
    do: "arg `#{ref_label}` came up empty — upstream lookup produced no entry at index #{idx}."

  # Walk `args` by a dotted path (the form `detect_index_miss/1` returns)
  # to fetch the original binding string. The path joins keys with "."
  # so we split it back into segments and walk.
  defp lookup_raw_binding(args, ref_label) when is_binary(ref_label) do
    Enum.reduce(String.split(ref_label, "."), args, fn
      _seg, nil -> nil
      seg, acc when is_map(acc) -> Map.get(acc, seg)
      _seg, _ -> nil
    end)
  end

  defp lookup_raw_binding(_, _), do: nil

  # Parse the binding to find the source node id, then read that node's
  # resolved input from the persisted step trace. Returns `nil` when the
  # binding doesn't reference a prior node (trigger inputs, owner refs,
  # etc.) or when the upstream step row isn't found.
  defp trace_upstream(ir, state, binding) when is_binary(binding) do
    case extract_ref_body(binding) do
      {:ok, body} ->
        case DmhAi.Workflows.Path.parse(body) do
          {:ok, %{root: {:node, n}}} ->
            up_node = find_node_by_id(ir, n)
            input   = read_step_input(state.id, n)

            %{
              node:     n,
              function: up_node && up_node["function"],
              input:    input
            }

          _ ->
            nil
        end

      :error ->
        nil
    end
  end

  defp trace_upstream(_, _, _), do: nil

  # Strip the surrounding `{{…}}` from a binding string. Returns
  # `:error` if the string isn't a single binding (literal value, or
  # text with embedded interpolation — neither is a node reference).
  defp extract_ref_body(s) when is_binary(s) do
    trimmed = String.trim(s)
    if String.starts_with?(trimmed, "{{") and String.ends_with?(trimmed, "}}") do
      body = trimmed |> String.slice(2..-3//1) |> String.trim()
      {:ok, body}
    else
      :error
    end
  end

  defp extract_ref_body(_), do: :error

  defp read_step_input(run_id, node_id) do
    case query!(Repo,
           "SELECT resolved_input FROM workflow_run_steps " <>
             "WHERE run_id=? AND node_id=? ORDER BY id DESC LIMIT 1",
           [run_id, node_id]).rows do
      [[ri]] when is_binary(ri) ->
        case Jason.decode(ri) do
          {:ok, %{"args" => args}} -> args
          {:ok, other}             -> other
          _                        -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Replace any `{:index_miss, i}` tuples with a human-readable marker
  # so the step's `resolved_input` JSON column round-trips through
  # `Jason.encode!`. The tuple is an internal signal; the persisted
  # form needs to be JSON-safe for the run-viewer UI.
  defp scrub_index_miss(value) when is_map(value),
    do: Enum.into(value, %{}, fn {k, v} -> {k, scrub_index_miss(v)} end)

  defp scrub_index_miss(value) when is_list(value),
    do: Enum.map(value, &scrub_index_miss/1)

  defp scrub_index_miss({:index_miss, i}),
    do: "<lookup_miss: index #{i} out of range>"

  defp scrub_index_miss(other), do: other

  # Recursively scan resolved args for any `{:index_miss, i}` tuple
  # left over from `Path.walk`. Returns `{:miss, <arg_name_path>, i}`
  # on the first hit, `:ok` when all args resolved cleanly. The label
  # gives the operator a hint about which arg's ref chain failed.
  defp detect_index_miss(args) when is_map(args) do
    Enum.find_value(args, :ok, fn {k, v} ->
      case detect_index_miss(v) do
        {:miss, sub, i} -> {:miss, "#{k}." <> sub, i}
        {:miss_root, i} -> {:miss, to_string(k), i}
        :ok             -> nil
      end
    end)
  end

  defp detect_index_miss(args) when is_list(args) do
    Enum.find_value(args, :ok, fn v ->
      case detect_index_miss(v) do
        {:miss, sub, i} -> {:miss, sub, i}
        {:miss_root, i} -> {:miss_root, i}
        :ok             -> nil
      end
    end)
  end

  defp detect_index_miss({:index_miss, i}), do: {:miss_root, i}
  defp detect_index_miss(_),                 do: :ok

  # Per-step failure routing — reads `on_failure[class]` from the
  # IR node, falls back to defaults the connector contract implies
  # (see `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency
  # / L4). The error envelope produced by upstream connectors carries
  # the class as `:error` (a stringified atom); we use it as the
  # lookup key.
  defp handle_step_failure(ir, node, state, step_id, fn_name, raw_error, n) do
    class  = error_class(raw_error)
    action = resolve_failure_action(node, class)

    err = %{
      error:    :step_failed,
      class:    class,
      node_id:  node["id"],
      function: fn_name,
      detail:   encode_err(raw_error)
    }

    apply_failure_action(action, ir, node, state, step_id, err, class, n)
  end

  # Extract the error class atom from whatever shape the dispatcher
  # returned. Connector envelopes use a stringified `:error` key
  # (`"rate_limited"`, `"unauthorised"`, …); we map known names to
  # known atoms and fall through to `:unknown` for anything else.
  # We deliberately don't use `String.to_existing_atom/1` — atom
  # creation by literal mention in this function pins the known
  # classes at compile time, and unknown strings stay unmapped.
  @known_error_classes %{
    "unauthorised"          => :unauthorised,
    "forbidden"             => :forbidden,
    "api_disabled"          => :api_disabled,
    "not_found"             => :not_found,
    "rate_limited"          => :rate_limited,
    "duplicate"             => :duplicate,
    "invalid_request"       => :invalid_request,
    "upstream_5xx"          => :upstream_5xx,
    "upstream_other"        => :upstream_other,
    "missing_credentials"   => :missing_credentials,
    "permission_denied"     => :permission_denied,
    "capability_disabled"   => :capability_disabled,
    "unknown_function"      => :unknown_function,
    "connector_not_registered" => :connector_not_registered,
    "write_requires_task"   => :write_requires_task,
    "adapter_crash"         => :adapter_crash,
    "lookup_miss"           => :lookup_miss
  }

  defp error_class(%{error: e}) when is_binary(e),
    do: Map.get(@known_error_classes, e, :unknown)

  defp error_class(%{error: e}) when is_atom(e), do: e
  defp error_class(e) when is_atom(e),           do: e
  defp error_class(_),                            do: :unknown

  defp resolve_failure_action(node, class) do
    per_class = Map.get(node, "on_failure", %{}) || %{}

    case Map.get(per_class, to_string(class)) do
      nil ->
        default_action_for(class)

      raw ->
        normalise_action(raw) || default_action_for(class)
    end
  end

  # Per-class defaults. The model rarely declares `on_failure:`
  # explicitly — these defaults match the connector contract's
  # implied semantics:
  #   - `:unauthorised` / `:missing_credentials` — needs re-auth,
  #     surface to user (pause).
  #   - everything else (rate_limited, 5xx, invalid_request, etc.)
  #     — fail the run; the run viewer surfaces the envelope and the
  #     user / admin investigates. Retry-with-backoff and rate-limit
  #     header handling are explicit overrides for now (no auto-retry
  #     until the timer mechanism lands; see the spec's L4 TODO).
  defp default_action_for(:unauthorised),         do: :pause_and_notify
  defp default_action_for(:missing_credentials),  do: :pause_and_notify
  defp default_action_for(_),                     do: :fail

  # Translate the IR's serialized action to a runtime action tuple.
  # Unknown shapes return nil so the caller can fall through to
  # `default_action_for/1`.
  defp normalise_action("fail"),              do: :fail
  defp normalise_action("pause_and_notify"),  do: :pause_and_notify
  defp normalise_action(%{"next" => id}) when is_integer(id), do: {:next, id}
  defp normalise_action(%{next: id}) when is_integer(id),     do: {:next, id}
  defp normalise_action(_),                   do: nil

  # ── failure-action dispatch ──────────────────────────────────────────

  defp apply_failure_action(:fail, _ir, _node, state, step_id, err, _class, _n) do
    Workflows.close_step(step_id, :failed, error: err)
    :ok = Workflows.complete_run(state.id, :failed, err)
    {:error, err}
  end

  defp apply_failure_action({:next, id}, ir, _node, state, step_id, err, _class, n) do
    # Close the failing step as audit, then route to the recovery
    # node. The IR's `on_failure: {<class>: {next: <id>}}` lets the
    # model encode "if not found, create it" semantics inline.
    Workflows.close_step(step_id, :failed, error: err)

    case find_node_by_id(ir, id) do
      nil ->
        err2 = Map.merge(err, %{error: :on_failure_next_not_found, target: id})
        :ok = Workflows.complete_run(state.id, :failed, err2)
        {:error, err2}

      next_node ->
        walk(ir, next_node, state, n + 1)
    end
  end

  defp apply_failure_action(:pause_and_notify, _ir, node, state, step_id, err, class, _n) do
    Workflows.close_step(step_id, :failed, error: err)

    :ok = Workflows.add_wait(state.id, node["id"], :reauth_pause,
                              %{"error" => err, "node_id" => node["id"]})
    :ok = Workflows.update_run(state.id, %{
            last_error:   err,
            status:       :waiting,
            current_node: node["id"]
          })

    Logger.info(
      "[Executor] paused-on-failure run=#{state.id} node=#{node["id"]} class=#{class}"
    )

    {:ok, Workflows.get_run!(state.id)}
  end

  defp dispatch_step(fn_name, args, _node, state) when fn_name in @synthetic_names do
    run_llm_synthetic(fn_name, args, state)
  end

  defp dispatch_step(fn_name, args, node, state) do
    ctx = %{
      user_id:        state.owner_user_id,
      act_as_user_id: node["act_as_user_id"],
      task_id:        state.task_id,
      org_id:         state.org_id,
      step_seq:       node["id"]
    }

    Catalog.call(fn_name, args, ctx)
  end

  # The executor invokes the LLM directly for synthetics — the
  # Catalog refuses dispatch (G5 carve-out). Compose-only role; one
  # structured reply expected to match the manifest's emits_schema.
  defp run_llm_synthetic("llm.compose", args, _state) do
    template = Map.get(args, "template") || Map.get(args, :template) || ""
    context  = Map.get(args, "context")  || Map.get(args, :context)  || %{}

    # v1 implementation: render via Mustache substitution on the
    # template using the context map. Future: swap in a Swift LLM
    # call when the template alone isn't enough.
    rendered = render_template(template, context)
    {:ok, %{"subject" => "", "body" => rendered, "rendered" => rendered}}
  end

  defp run_llm_synthetic("llm.summarise", args, _state) do
    text = Map.get(args, "text") || Map.get(args, :text) || ""
    {:ok, %{"summary" => String.slice(text, 0, 400)}}
  end

  defp run_llm_synthetic("builtin.compute", args, _state) do
    expr = Map.get(args, "expr") || Map.get(args, :expr) || ""
    {:ok, %{"result" => expr}}    # v1 placeholder; arithmetic eval not yet implemented
  end

  # `builtin.coalesce` — null-coalescing primitive for the join /
  # merge problem. Branches that converge on a downstream step's
  # arg (typical pattern: `contact.find` succeeds OR `contact.create`
  # runs as a fallback; downstream `deal.create` needs ONE contact_id
  # regardless of which path ran) put a `coalesce` step at the join
  # point. Its `values:` arg is an ordered list; the executor picks
  # the first non-nil value and emits it as `value`.
  #
  #   - id: 4
  #     kind: step
  #     function: builtin.coalesce
  #     args:
  #       values:
  #         - "{{1.contact_id}}"   # from contact.find (the happy path)
  #         - "{{3.contact_id}}"   # from contact.create (the fallback)
  #     emits: { value: $.value }
  #     next: 5
  #   - id: 5
  #     kind: step
  #     function: hubspot.deal.create
  #     args:
  #       contact_id: "{{4.value}}"
  #       …
  #
  # The args are resolved by the executor's normal binding pass
  # before this synthetic runs; we see the already-substituted
  # values (nil for branches that didn't execute).
  defp run_llm_synthetic("builtin.coalesce", args, _state) do
    values = Map.get(args, "values") || Map.get(args, :values) || []

    picked =
      values
      |> List.wrap()
      |> Enum.find(fn v -> not is_nil(v) and v != "" end)

    {:ok, %{"value" => picked}}
  end

  defp render_template(template, context) when is_binary(template) and is_map(context) do
    Regex.replace(~r/\{\{([^}]+)\}\}/, template, fn _full, key ->
      key = String.trim(key)
      val = Map.get(context, key) || Map.get(context, String.to_atom(key)) || ""
      to_string(val)
    end)
  end

  defp render_template(_, _), do: ""

  # ── branch ───────────────────────────────────────────────────────────

  defp handle_branch(ir, node, state, n) do
    step_id = Workflows.open_step(state.id, node["id"],
      %{cases: Map.get(node, "cases", []), else: Map.get(node, "else")})

    {next_id, matched_when} =
      case pick_branch(node["cases"] || [], state) do
        nil ->
          else_next =
            case Map.get(node, "else") do
              %{"next" => nid} -> nid
              _ -> nil
            end

          {else_next, nil}

        %{"next" => nid, "when" => w} ->
          {nid, w}

        %{"next" => nid} ->
          {nid, nil}
      end

    Workflows.close_step(step_id, :completed,
      output: %{branched_to_node: next_id, matched_when: matched_when})

    next = find_node_by_id(ir, next_id)
    walk(ir, next, state, n + 1)
  end

  defp pick_branch([], _state), do: nil

  defp pick_branch([%{"when" => predicate} = c | rest], state) do
    if eval_predicate(predicate, state), do: c, else: pick_branch(rest, state)
  end

  defp pick_branch([%{"else" => _} | _], _state), do: nil

  defp pick_branch([_ | rest], state), do: pick_branch(rest, state)

  # Predicate evaluation uses the dedicated `DmhAi.Workflows.Expression`
  # parser. Compile-time validator (`upsert_workflow.ex
  # check_branch_predicates/1`) has already rejected malformed
  # expressions, so we expect `parse/1` to succeed; the bare-parse
  # rescue below handles the residual edge where state-injected
  # bindings produced an unparseable string.
  defp eval_predicate(pred, state) when is_binary(pred) do
    case DmhAi.Workflows.Expression.parse(pred) do
      {:ok, ast} ->
        DmhAi.Workflows.Expression.evaluate(ast, fn path ->
          resolve_ref_body(path, state)
        end)

      {:error, _} ->
        false
    end
  end

  defp eval_predicate(_, _), do: false

  # ── gate (approval) ──────────────────────────────────────────────────

  defp handle_gate(_ir, node, state, _n) do
    # Suspend at the gate. The approver receives a notification
    # via Primitive 0.4; on decision, resume_run/2 fires.
    pred = %{
      "approver"     => Map.get(node, "approver", %{}),
      "context"      => Map.get(node, "context", %{}),
      "node_id"      => node["id"]
    }

    step_id = Workflows.open_step(state.id, node["id"],
      %{approver: pred["approver"], context: pred["context"]})
    Workflows.close_step(step_id, :waiting, waiting_on: %{kind: "approval", predicate: pred})

    :ok = Workflows.add_wait(state.id, node["id"], :approval, pred)
    Logger.info("[Executor] suspended at gate run=#{state.id} node=#{node["id"]}")
    {:ok, Workflows.get_run!(state.id)}
  end

  # ── wait ─────────────────────────────────────────────────────────────

  defp handle_wait(_ir, node, state, _n) do
    timeout_s = Map.get(node, "timeout_seconds")
    expires   = timeout_s && System.os_time(:second) + timeout_s

    pred = %{
      "trigger"      => Map.get(node, "trigger", %{}),
      "node_id"      => node["id"]
    }

    kind =
      case Map.get(node, "trigger", %{}) |> Map.get("kind") do
        "webhook"  -> :webhook
        "schedule" -> :schedule
        _          -> :webhook
      end

    step_id = Workflows.open_step(state.id, node["id"], pred)
    Workflows.close_step(step_id, :waiting,
      waiting_on: %{kind: kind, predicate: pred, expires_at: expires})

    :ok = Workflows.add_wait(state.id, node["id"], kind, pred, expires)
    Logger.info("[Executor] suspended at wait run=#{state.id} node=#{node["id"]}")
    {:ok, Workflows.get_run!(state.id)}
  end

  defp find_next_after_wait(_ir, %{"on_fire" => nid}, _payload), do: nid
  defp find_next_after_wait(_ir, %{"next" => nid}, _payload),    do: nid
  defp find_next_after_wait(_ir, _, _), do: nil

  # ── output ───────────────────────────────────────────────────────────

  defp handle_output(_ir, node, state) do
    raw_emit = Map.get(node, "emit", %{})
    emit     = resolve_args(raw_emit, state)
    step_id  = Workflows.open_step(state.id, node["id"], raw_emit)
    Workflows.close_step(step_id, :completed, output: emit)

    new_bindings = put_emits(state.bindings, node["id"], emit)
    :ok = Workflows.update_run(state.id, %{bindings: new_bindings})
    :ok = Workflows.complete_run(state.id, :completed)
    Logger.info("[Executor] completed run=#{state.id} via node=#{node["id"]}")
    {:ok, Workflows.get_run!(state.id)}
  end

  # ── binding resolution ──────────────────────────────────────────────
  #
  # All ref discovery + parsing goes through `Workflows.Refs`
  # (over args) → `Workflows.Mustache` (over strings) →
  # `Workflows.Path` (over each ref body). Single-pass state
  # machines, no regex. The walker handles the typed accessors
  # against runtime data.
  #
  # Two surfaces:
  #
  #   * `resolve_args/2` — substitutes refs across an arbitrary
  #     args value (map / list / string / scalar). Used to prepare
  #     the args BEFORE the tool call.
  #
  #   * `resolve_string_for_predicate/2` — strict string form for
  #     predicate operands (lhs/rhs of `==`/`!=` in branch nodes).
  #     Always returns a string so the comparator has typed operands
  #     after `normalise_operand/1`.

  alias DmhAi.Workflows.{Path, Refs}

  defp resolve_args(args, state) when is_map(args) do
    Refs.substitute(args, fn body -> resolve_ref_body(body, state) end)
  end

  defp resolve_args(other, _), do: other

  # A single ref body resolver. Receives the trimmed inner content
  # of a `{{…}}`; returns the resolved value, or `:passthrough` if
  # the runtime can't resolve it (the template stays untouched so
  # downstream synthetic primitives can resolve it themselves).
  defp resolve_ref_body(body, state) do
    case Path.parse(body) do
      {:error, _reason} ->
        :passthrough

      {:ok, %{root: :now,   path: []}} ->
        DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, %{root: :today, path: []}} ->
        Date.utc_today() |> Date.to_iso8601()

      {:ok, %{root: :trigger, path: path}} ->
        data = state.bindings["trigger"] || state.bindings[:trigger] || %{}
        Path.walk(data, path) |> walked_or_empty()

      {:ok, %{root: :owner, path: path}} ->
        owner_record(state.owner_user_id)
        |> Path.walk(path)
        |> walked_or_empty()

      {:ok, %{root: :org, path: path}} ->
        org_record(state.org_id)
        |> Path.walk(path)
        |> walked_or_empty()

      {:ok, %{root: {:node, id}, path: path}} ->
        emits = state.bindings["emits"] || state.bindings[:emits] || %{}
        node_emit = Map.get(emits, to_string(id)) || Map.get(emits, id, %{})
        Path.walk(node_emit, path) |> walked_or_empty()

      {:ok, _other} ->
        :passthrough
    end
  end

  defp walked_or_empty(:not_found), do: ""
  defp walked_or_empty(nil),         do: ""
  defp walked_or_empty(v),           do: v

  # ── emits ────────────────────────────────────────────────────────────

  # `emits` is the IR's declaration of which fields downstream
  # nodes may bind against. v1 supports two forms:
  #   * shorthand list `["field_a", "field_b"]` → pluck top-level keys
  #     from the result and expose them.
  #   * map `%{out_name: "$.json.path"}` → JSONPath lookup
  defp extract_emits(node, result) when is_map(result) do
    case Map.get(node, "emits") do
      m when is_map(m) ->
        Enum.into(m, %{}, fn {k, _path} ->
          {k, Map.get(result, k) || Map.get(result, to_string(k))}
        end)

      l when is_list(l) ->
        Enum.into(l, %{}, fn k -> {k, Map.get(result, k) || Map.get(result, to_string(k))} end)

      _ ->
        result
    end
  end

  defp extract_emits(_node, result), do: %{"value" => result}

  defp put_emits(bindings, node_id, emit) when is_map(bindings) do
    cur = Map.get(bindings, "emits") || Map.get(bindings, :emits) || %{}
    new_emits = Map.put(cur, to_string(node_id), emit)
    Map.put(bindings, "emits", new_emits)
  end

  # ── owner / org lookups ──────────────────────────────────────────────

  defp owner_record(user_id) do
    base =
      case query!(Repo, """
      SELECT id, email, name, org_id, org_role
        FROM users WHERE id=?
      """, [user_id]).rows do
        [[id, email, name, org, role]] ->
          %{"user_id" => id, "id" => id,
            "email" => email, "name" => name || "",
            "display_name" => name || email,
            "org_id" => org, "org_role" => role}

        _ ->
          %{}
      end

    # Embed per-connector identity sub-maps so `{{owner.<slug>.email}}`
    # resolves to the email the user OAuth'd with AT THAT VENDOR. This
    # is distinct from `{{owner.email}}` (the DMH-AI app email): a user
    # may sign into DMH-AI as `admin@acme.com` but connect HubSpot as
    # `sales-ops@acme.com`. Most workflows that look up the user's own
    # vendor record (CRM contact, calendar, mailbox) want the VENDOR
    # email, not the app email.
    Map.merge(base, connector_identities(user_id))
  rescue
    _ -> %{}
  end

  # One DB hit per resolution; cheap because there are at most a
  # handful of `oauth:<slug>` rows per user. Returns a map keyed by
  # slug → `%{"email" => <vendor email>}` for every connector the
  # user has authorised AND whose OAuth callback successfully
  # captured the userinfo email into the credential row's `account`
  # column. Slugs without an `account` value (the userinfo call
  # failed, the vendor exposes no email, the OAuth flow predates
  # this wiring) are absent — accessing them resolves to "" via
  # the executor's `walked_or_empty/1` fallback, which makes the
  # missing-data signal recoverable through `on_failure: lookup_miss`
  # the same way an empty `<vendor>.find` list does.
  defp connector_identities(user_id) do
    %{rows: rows} =
      query!(Repo, """
      SELECT target, account
        FROM user_credentials
       WHERE user_id = ?
         AND target LIKE 'oauth:%'
         AND account IS NOT NULL
         AND account <> ''
      """, [user_id])

    Enum.into(rows, %{}, fn [target, account] ->
      slug = String.replace_prefix(target, "oauth:", "")
      {slug, %{"email" => account, "account" => account}}
    end)
  end

  defp org_record(org_id) do
    case query!(Repo, "SELECT id, name FROM organizations WHERE id=?", [org_id]).rows do
      [[id, name]] -> %{"id" => id, "name" => name || ""}
      _ -> %{"id" => org_id}
    end
  rescue
    _ -> %{"id" => org_id}
  end

  # ── helpers ──────────────────────────────────────────────────────────

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

  defp find_node_by_id(_ir, nil), do: nil

  defp find_node_by_id(ir, id) do
    nodes = Map.get(ir, "nodes") || []
    Enum.find(nodes, fn n -> n["id"] == id end)
  end

  defp encode_err(e) when is_atom(e) or is_binary(e), do: inspect(e)
  defp encode_err(%{} = m),                            do: m
  defp encode_err(other),                              do: inspect(other)
end
