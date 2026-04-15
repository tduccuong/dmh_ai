defmodule Dmhai.Adapters.Telegram do
  @moduledoc """
  Telegram adapter — skeleton / wiring.

  Dual role
  ---------
  1. INPUT: Receives messages from users via Telegram Bot API and routes them
     to their UserAgent via Dmhai.Agent.UserAgent.dispatch/2.

  2. NOTIFICATION: Called by MsgGateway.notify/2 to push a message to the
     user's Telegram chat when an async worker finishes.

  Current state
  -------------
  The Bot API polling loop and webhook handler are NOT yet implemented.
  The `notify/2` function is the only live path — it sends a message to the
  user's known Telegram chat_id (stored in UserAgent platform_state).

  To activate full Telegram support:
  1. Set config :dmhai, :telegram_bot_token, "YOUR_TOKEN"
  2. Implement `start_polling/0` (long-poll getUpdates loop) or a webhook
     endpoint in the router (`POST /webhooks/telegram`).
  3. Map incoming chat_id → user_id via the `telegram_users` DB table (TBD).
  4. Build a Command and call UserAgent.dispatch/2.

  TODO items are marked with "TODO:" below.
  """

  @behaviour Dmhai.Agent.Adapter

  require Logger

  alias Dmhai.Agent.UserAgent

  # ─── GenServer for polling (skeleton) ─────────────────────────────────────
  # TODO: uncomment and implement when activating Telegram
  #
  # use GenServer
  #
  # def start_link(_opts) do
  #   GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  # end
  #
  # def init(:ok) do
  #   if bot_token() do
  #     schedule_poll()
  #     {:ok, %{offset: 0}}
  #   else
  #     Logger.info("[Telegram] no bot token configured, adapter inactive")
  #     :ignore
  #   end
  # end
  #
  # def handle_info(:poll, state) do
  #   offset = poll_updates(state.offset)
  #   schedule_poll()
  #   {:noreply, %{state | offset: offset}}
  # end
  #
  # defp schedule_poll, do: Process.send_after(self(), :poll, 1_000)
  #
  # defp poll_updates(offset) do
  #   # GET https://api.telegram.org/bot<TOKEN>/getUpdates?offset=<offset>&timeout=25
  #   # For each update: resolve user_id, build Command, dispatch
  #   # Return next offset
  #   offset
  # end

  # ─── Adapter callbacks ─────────────────────────────────────────────────────

  @impl true
  def send_chunk(_ctx, _chunk) do
    # TODO: for streaming Telegram responses, edit the in-progress message
    # ctx = {chat_id, message_id}
    :ok
  end

  @impl true
  def send_done(_ctx, _result) do
    # TODO: finalize the Telegram message with the complete response
    :ok
  end

  @impl true
  def send_error(_ctx, _reason) do
    # TODO: edit the Telegram message to show an error
    :ok
  end

  @impl true
  def notify(user_id, message) do
    case UserAgent.get_platform_state(user_id, :telegram) do
      %{chat_id: chat_id} when is_binary(chat_id) ->
        send_message(chat_id, message)

      _ ->
        Logger.debug("[Telegram] no chat_id for user=#{user_id}, skipping notify")
        :ok
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp send_message(chat_id, text) do
    token = bot_token()

    if is_nil(token) do
      Logger.warning("[Telegram] bot token not configured, cannot send to chat_id=#{chat_id}")
      {:error, :no_token}
    else
      url = "https://api.telegram.org/bot#{token}/sendMessage"

      case Req.post(url,
             json: %{chat_id: chat_id, text: text, parse_mode: "Markdown"},
             receive_timeout: 10_000
           ) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.warning("[Telegram] sendMessage failed status=#{status} body=#{inspect(body)}")
          {:error, status}

        {:error, reason} ->
          Logger.error("[Telegram] sendMessage error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp bot_token do
    Application.get_env(:dmhai, :telegram_bot_token)
  end
end
