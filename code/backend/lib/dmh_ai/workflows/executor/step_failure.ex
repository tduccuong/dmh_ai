# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.StepFailure do
  @moduledoc """
  Per-step failure routing — reads `on_failure[class]` from the
  IR node, falls back to defaults the connector contract implies
  (see `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency
  / L4). The error envelope produced by upstream connectors carries
  the class as `:error` (a stringified atom); we use it as the
  lookup key.
  """

  alias DmhAi.Workflows
  alias DmhAi.Workflows.Executor
  require Logger

  # The error envelope produced by upstream connectors carries the
  # class as `:error` (a stringified atom); we map known names to
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

  @doc """
  Resolve the failure class from the raw error, look up the IR's
  per-class action (with sensible defaults), and dispatch the
  resulting action (`:fail` / `{:next, id}` / `:pause_and_notify`).
  """
  def handle_step_failure(ir, node, state, step_id, fn_name, raw_error, n) do
    class  = error_class(raw_error)
    action = resolve_failure_action(node, class)

    err = %{
      error:    :step_failed,
      class:    class,
      node_id:  node["id"],
      function: fn_name,
      detail:   Executor.encode_err(raw_error)
    }

    apply_failure_action(action, ir, node, state, step_id, err, class, n)
  end

  # Extract the error class atom from whatever shape the dispatcher
  # returned.
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

  # ── failure-action dispatch ─────────────────────────────────────────

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

    case Executor.find_node_by_id(ir, id) do
      nil ->
        err2 = Map.merge(err, %{error: :on_failure_next_not_found, target: id})
        :ok = Workflows.complete_run(state.id, :failed, err2)
        {:error, err2}

      next_node ->
        Executor.walk(ir, next_node, state, n + 1)
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
end
