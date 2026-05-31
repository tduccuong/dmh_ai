# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.SignalBlocker do
  @moduledoc """
  Chain-terminating signal: the model declares it is blocked and the
  chain ends with that statement as the user-visible message.

  Use when the right termination after an exhausted probe loop is a
  blocker statement (the missing input isn't a form field — it's a
  judgement call, an out-of-band dependency, or a class of input the
  runtime can't collect via `request_input`). Police recognises the
  call as the honest ending: outcome-writes that errored earlier in
  the chain are no longer phantom outcomes once a blocker is signalled.

  Not a write — `write_class: :read`. Doesn't enter the outcome tally.
  The chain loop treats it the same way it treats `request_input`:
  the call BECOMES the final assistant message; no subsequent text
  turn is needed (and none should be emitted).

  See architecture.md §Chain termination / §Honest blockers.
  """

  @behaviour DmhAi.Tools.Behaviour

  @impl true
  def name, do: "signal_blocker"

  @impl true
  def description do
    """
    End the chain with an honest blocker statement when no probe can fill the gap.

    Call `signal_blocker(reason: <one-sentence statement of the gap>, missing_input?: <short noun phrase naming what would unblock>)` when the right termination is to surface a specific blocker — the chain ends and `reason` becomes the user-visible message. The `missing_input` field is optional but recommended when there IS a specific input that would unblock; omit it when the blocker is "the user has to decide" or "an external system has to act first".

    Use this INSTEAD OF a text-only "I'm blocked" reply after a failed outcome-write. The text-only path is treated as a phantom outcome by the runtime — `signal_blocker` is the honest signal.

    Don't call `signal_blocker` and another tool in the same turn — this is a chain-terminator.
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          reason: %{
            type: "string",
            description: "One sentence naming the gap. Becomes the user-visible message."
          },
          missing_input: %{
            type: "string",
            description: "Optional short noun phrase naming what would unblock (e.g. 'routable IP or FQDN', 'admin approval', 'vendor outage to clear'). Omit when no specific input applies."
          }
        },
        required: ["reason"]
      }
    }
  end

  @impl true
  def execute(%{"reason" => reason} = args, _ctx) when is_binary(reason) and reason != "" do
    blocker = %{
      reason:        reason,
      missing_input: Map.get(args, "missing_input")
    }

    # Nested `:blocker` key is the chain loop's hook — the same shape
    # `request_input` uses with `:form`. The chain loop reads the
    # nested map, ends the chain, and surfaces `reason` as the user-
    # visible message.
    {:ok, %{blocker: blocker, acknowledged: true}}
  end

  def execute(_, _), do: {:error, "reason (non-empty string) is required"}
end
