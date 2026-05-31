# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.Step do
  @moduledoc """
  Step-node handler. Resolves the node's `args` against the run
  bindings, performs the index-miss pre-flight (so an out-of-range
  array lookup surfaces as a typed `:lookup_miss` failure BEFORE
  the vendor call), dispatches via `StepDispatch`, and on failure
  hands off to `StepFailure` for per-class routing.

  Also owns the `read_step_input/2` cache reader and the recursive
  index-miss scrub / detect helpers used to build the `:lookup_miss`
  envelope.
  """

  alias DmhAi.{Repo, Workflows}
  alias DmhAi.Workflows.Executor
  alias DmhAi.Workflows.Executor.{Bindings, StepDispatch, StepFailure}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Top-level step handler invoked by the walker's `dispatch_node/4`.
  """
  def handle_step(ir, node, state, n) do
    fn_name = node["function"]
    args    = Bindings.resolve_args(node["args"] || %{}, state)

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
        StepFailure.handle_step_failure(ir, node, state, step_id, fn_name, err, n)

      :ok ->
        step_id = Workflows.open_step(state.id, node["id"],
          %{function: fn_name, args: args})

        case StepDispatch.dispatch_step(fn_name, args, node, state) do
          {:ok, result} ->
            emit = Bindings.extract_emits(node, result)
            Workflows.close_step(step_id, :completed, output: emit)
            new_bindings = Bindings.put_emits(state.bindings, node["id"], emit)
            :ok = Workflows.update_run(state.id, %{bindings: new_bindings})
            next = Executor.find_node_by_id(ir, node["next"])
            Executor.walk(ir, next, %{state | bindings: new_bindings}, n + 1)

          {:error, e} ->
            StepFailure.handle_step_failure(ir, node, state, step_id, fn_name, e, n)
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
            up_node = Executor.find_node_by_id(ir, n)
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
end
