# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.MsgGateway do
  @moduledoc """
  Notification bus — multicasts a message to all configured messaging platforms.

  Configuration
  -------------
  In config/config.exs (or runtime.exs):

      config :dmhai, :msg_platforms, [:telegram]   # default

  Adding a platform
  -----------------
  1. Create `lib/dmhai/adapters/<platform>.ex` implementing Dmhai.Agent.Adapter.
  2. Add a `notify_platform/3` clause below.
  3. Add the platform atom to :msg_platforms in config.

  Usage
  -----
      MsgGateway.notify(user_id, "Your booking is confirmed ✓")
  """

  require Logger

  @default_platforms [:telegram]

  @doc """
  Send `message` to the user on every configured platform.
  Failures on individual platforms are logged but do not halt others.
  """
  @spec notify(String.t(), String.t()) :: :ok
  def notify(user_id, message) do
    platforms()
    |> Enum.each(fn platform ->
      try do
        notify_platform(platform, user_id, message)
      rescue
        e ->
          Logger.error("[MsgGateway] #{platform} notify failed user=#{user_id}: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  # ─── Platform dispatch ─────────────────────────────────────────────────────

  defp notify_platform(:telegram, user_id, message) do
    Dmhai.Adapters.Telegram.notify(user_id, message)
  end

  # Catch-all for unknown / future platforms
  defp notify_platform(platform, _user_id, _message) do
    Logger.warning("[MsgGateway] unknown platform: #{inspect(platform)}")
    :ok
  end

  # ─── Config ───────────────────────────────────────────────────────────────

  defp platforms do
    Application.get_env(:dmhai, :msg_platforms, @default_platforms)
  end
end
