# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.DeclarePeriodic do
  @moduledoc """
  Worker tool: declare that this is a long-running periodic task.

  Calling this lifts the iteration cap (default 20) so the worker can
  run indefinitely.  The worker loop detects this tool call and sets
  periodic=true in its control state before executing anything else.

  Call once at the start of a periodic task, before the first spawn_task.
  """

  @behaviour Dmhai.Tools.Behaviour

  @impl true
  def name, do: "declare_periodic"

  @impl true
  def description,
    do:
      "Declare that this task is long-running and periodic (e.g. monitor every N seconds). " <>
        "This lifts the iteration cap so you can run indefinitely. " <>
        "Call this ONCE at the very start before entering your periodic loop. " <>
        "Then use spawn_task with delay_ms for timed repetition, " <>
        "and midjob_notify to push each update to the user."

  @impl true
  def execute(_args, _ctx) do
    {:ok,
     "Periodic mode enabled. Iteration cap lifted. " <>
       "Use spawn_task(delay_ms: N) for timed sub-tasks and midjob_notify to push results."}
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  end
end
