# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Plugs.RateLimit do
  @moduledoc """
  Hammer-backed rate limiter. Three tiers keyed by real client IP:

    auth    — 8 req/min   (/auth/*)
    upload  — 30 req/min  (/assets, /describe-video, /describe-image)
    general — 120 req/min (everything else)

  Real IP is read from X-Forwarded-For (first entry) when present,
  falling back to conn.remote_ip for direct connections.
  """
  import Plug.Conn
  require Logger

  @scale_ms 60_000

  @limits %{
    auth:    8,
    upload:  30,
    general: 120
  }

  @upload_paths ~w(/assets /describe-video /describe-image)

  def init(opts), do: opts

  def call(conn, _opts) do
    ip    = client_ip(conn)
    tier  = tier_for(conn.request_path)
    limit = @limits[tier]

    case Hammer.check_rate("#{ip}:#{tier}", @scale_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "Too many requests"}))
        |> halt()
    end
  end

  defp tier_for(path) do
    cond do
      String.starts_with?(path, "/auth") ->
        :auth
      Enum.any?(@upload_paths, &String.starts_with?(path, &1)) ->
        :upload
      true ->
        :general
    end
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [xff | _] -> xff |> String.split(",") |> List.first() |> String.trim()
      []        -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
