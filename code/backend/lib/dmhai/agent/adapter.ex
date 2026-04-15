defmodule Dmhai.Agent.Adapter do
  @moduledoc """
  Behaviour that every messaging adapter must implement.

  An adapter translates platform-specific messages into Agent.Command structs
  and delivers responses back to its platform.

  Response callbacks
  ------------------
  During an inline (streaming) command the agent's task calls:

      send_chunk(ctx, text)   — zero or more times as tokens arrive
      send_done(ctx, result)  — exactly once when complete
      send_error(ctx, reason) — exactly once on failure (instead of send_done)

  For async worker notifications (adapter may be called outside a request):

      notify(user_id, message) — push a one-shot notification to the user
  """

  @type ctx :: any()

  @doc "Stream a partial token to the user."
  @callback send_chunk(ctx(), chunk :: String.t()) :: :ok

  @doc "Signal successful completion."
  @callback send_done(ctx(), result :: map()) :: :ok

  @doc "Signal an error."
  @callback send_error(ctx(), reason :: String.t()) :: :ok

  @doc "Push an async notification (e.g. worker result ready)."
  @callback notify(user_id :: String.t(), message :: String.t()) :: :ok | {:error, term()}
end
