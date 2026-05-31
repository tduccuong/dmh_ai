# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data.TokenStats do
  @moduledoc """
  Admin-only per-session token-cost endpoint.

  Returns the per-tier rx/tx breakdown for this session plus the
  user's global aggregate, and the rx+tx grand total across all
  tiers for quick display.
  """

  import Plug.Conn
  alias DmhAi.Agent.TokenTracker
  alias DmhAi.Handlers.Data

  # GET /sessions/:session_id/token-stats (admin only)
  #
  # Returns the per-tier rx/tx breakdown for this session and the
  # user's global aggregate (summed across every row including the
  # `_user_global` sentinel that holds session-less calls — see
  # `DmhAi.Agent.TokenTracker`). The top-level `total` field is the
  # rx+tx grand total across all five tiers for quick display.
  def get_token_stats(conn, user, session_id) do
    if user.role != "admin" do
      Data.json(conn, 403, %{error: "Forbidden"})
    else
      stats  = TokenTracker.get_session_stats(session_id)
      global = TokenTracker.get_global_stats(user.id)

      payload = %{
        session: stats,
        global:  global,
        session_total: tier_grand_total(stats),
        global_total:  tier_grand_total(global)
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(payload))
    end
  end

  # Sum rx+tx across every tier in a TokenTracker stats map. Used by
  # the /token-stats endpoint to give the FE a single "grand total"
  # number per scope without re-implementing the addition client-side.
  def tier_grand_total(stats) when is_map(stats) do
    Enum.reduce(stats, 0, fn {_tier, %{rx: rx, tx: tx}}, acc -> acc + rx + tx end)
  end

  def tier_grand_total(_), do: 0
end
