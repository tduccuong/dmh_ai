# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.Triggers do
  @moduledoc """
  Poll-trigger manifest + cadence enforcement.

    * `check_poll_trigger_manifest/1` — poll triggers must name a
      connector function whose manifest declares
      `poll_trigger_capable: true` with the cursor protocol fields.
      A workflow that names a non-pollable function as its poll
      connector is broken at compile time — surface it now rather
      than let the Poller fail at every tick.

    * `check_trigger_cadence/1` — every poll/schedule needs a
      cadence:
        - poll: `every_seconds` integer, ≥ manifest
          `min_poll_seconds` floor.
        - schedule: `every_seconds` (v1) OR `cron` (v2; accepted
          but not yet executed).
      Distinct messages so the model knows which side it tripped.

    * `validate_poll_cadence/1` — the poll branch (extracted so the
      shell can run it independently if needed in future tests).
  """

  alias DmhAi.Connectors.Manifest, as: ConnectorManifest

  @doc """
  Reject a poll-trigger node whose `connector_function` either
  doesn't exist in any manifest or doesn't declare poll capability.
  """
  @spec check_poll_trigger_manifest([map()]) :: :ok | {:error, String.t()}
  def check_poll_trigger_manifest(nodes) do
    trigger = Enum.find(nodes, fn n -> n["kind"] == "trigger" end)

    case trigger do
      %{"trigger_kind" => "poll"} = t ->
        case Map.get(t, "connector_function") do
          nil ->
            {:error,
             "upsert_workflow: poll trigger (node #{t["id"]}) must declare `connector_function`"}

          fn_name when is_binary(fn_name) ->
            case poll_capable?(fn_name) do
              :ok ->
                :ok

              {:error, why} ->
                {:error,
                 "upsert_workflow: poll trigger node #{t["id"]} — `#{fn_name}` is not poll-trigger-capable: #{why}"}
            end
        end

      _ ->
        :ok
    end
  end

  @doc """
  Cadence enforcement. Per layer-W.md §Cadence:
    * poll triggers must have every_seconds AND
      ≥ manifest.min_poll_seconds
    * schedule triggers must have every_seconds (positive int) or
      cron (string)
  Distinct error messages so the model knows which side it tripped.
  """
  @spec check_trigger_cadence([map()]) :: :ok | {:error, String.t()}
  def check_trigger_cadence(nodes) do
    trigger = Enum.find(nodes, fn n -> n["kind"] == "trigger" end)

    case trigger do
      %{"trigger_kind" => "poll"} = t ->
        validate_poll_cadence(t)

      %{"trigger_kind" => "schedule"} = t ->
        validate_schedule_cadence(t)

      _ ->
        :ok
    end
  end

  @doc """
  Poll cadence branch of `check_trigger_cadence/1`. Enforces the
  `every_seconds` integer is present, positive, and at or above
  the function's manifest floor.
  """
  @spec validate_poll_cadence(map()) :: :ok | {:error, String.t()}
  def validate_poll_cadence(trigger) do
    every = Map.get(trigger, "every_seconds")
    fn_name = Map.get(trigger, "connector_function")

    floor = poll_floor_for(fn_name)
    default = poll_default_for(fn_name)

    cond do
      not is_integer(every) ->
        {:error,
         "upsert_workflow: poll trigger (node #{trigger["id"]}) must declare " <>
           "`every_seconds: <integer>`. Connector `#{fn_name}` recommends " <>
           "`#{default}` and requires at least `#{floor}`. " <>
           "Pick a cadence from the user's prose (\"real-time\" → floor; " <>
           "\"every few minutes\" → 300; \"hourly\" → 3600; no hint → recommended)."}

      every <= 0 ->
        {:error,
         "upsert_workflow: poll trigger `every_seconds` must be positive (got #{every})"}

      is_integer(floor) and every < floor ->
        {:error,
         "upsert_workflow: poll trigger `every_seconds=#{every}` is below the " <>
           "connector's floor for `#{fn_name}` (min_poll_seconds=#{floor}). " <>
           "Raise to at least #{floor}, or pick the recommended #{default}."}

      true ->
        :ok
    end
  end

  defp validate_schedule_cadence(trigger) do
    every = Map.get(trigger, "every_seconds")
    cron  = Map.get(trigger, "cron")

    cond do
      is_binary(cron) and cron != "" ->
        # v1 doesn't execute cron strings yet, but the IR can carry
        # them — the future cron evaluator will pick them up. For now
        # accept and move on.
        :ok

      is_integer(every) and every > 0 ->
        :ok

      true ->
        {:error,
         "upsert_workflow: schedule trigger (node #{trigger["id"]}) needs " <>
           "either `every_seconds: <positive integer>` (v1 cadence form) " <>
           "or `cron: \"<expression>\"` (v2; not yet executed but accepted). " <>
           "Pick one. If the user said \"daily\" use `86400`; \"every Monday\" " <>
           "use a cron expression."}
    end
  end

  defp poll_floor_for(fn_name),    do: poll_manifest_field(fn_name, :min_poll_seconds)
  defp poll_default_for(fn_name),  do: poll_manifest_field(fn_name, :default_poll_seconds)

  defp poll_manifest_field(nil, _key), do: nil
  defp poll_manifest_field(fn_name, key) when is_binary(fn_name) do
    case ConnectorManifest.lookup_fqn(fn_name) do
      %{} = spec -> Map.get(spec, key)
      nil        -> nil
    end
  end

  defp poll_capable?(fn_name) do
    case ConnectorManifest.lookup_fqn(fn_name) do
      nil ->
        {:error,
         "unknown function `#{fn_name}` — name must be `<slug>.<function>` and the " <>
           "connector must be configured + discovered"}

      %{poll_trigger_capable: true} ->
        :ok

      %{} ->
        {:error,
         "function `#{fn_name}` does not declare `poll_trigger_capable: true` " <>
           "(connector functions must declare cursor protocol in their manifest " <>
           "to be usable as a poll trigger — see layer-W.md §Cursor semantics)"}
    end
  end
end
