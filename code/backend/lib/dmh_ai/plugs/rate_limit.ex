# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Plugs.RateLimit do
  @moduledoc """
  Hammer-backed rate limiter. Four tiers keyed by the authenticated
  user when possible, falling back to client IP for pre-auth paths.

  See specs/architecture.md §Rate limiting for the full sizing rationale
  and tradeoffs. The short version:

    auth    —    8 req/min  (IP-keyed; login flood protection)
    upload  —   30 req/min  (/assets, /describe-video, /describe-image)
    poll    — 1200 req/min  (/sessions/:id/poll, /sessions/:id/tasks,
                              /sessions/:id/progress — the FE's delta
                              polling surface; sized for hours-long
                              tool-heavy chains, see architecture.md
                              §Rate limiting)
    general —  120 req/min  (everything else)

  Keying: `"user:<user_id>:<tier>"` when the request carries a valid
  bearer token; `"ip:<addr>:<tier>"` otherwise. Per-user keying is
  required so that multiple users behind a shared NAT (typical SME
  office deployment) do not collide into a single bucket.
  """
  import Plug.Conn
  import Ecto.Adapters.SQL, only: [query!: 3]
  alias DmhAi.Repo
  require Logger

  @scale_ms 60_000

  @limits %{
    auth:    8,
    upload:  30,
    poll:    1200,
    general: 120
  }

  @upload_paths ~w(/assets /describe-video /describe-image)

  # Matched by prefix on request_path. Leading /sessions/<id>/ is then
  # further matched on suffix via String.ends_with?/2 in tier_for/1.
  @poll_suffixes ~w(/poll /tasks /progress)

  def init(opts), do: opts

  def call(conn, _opts) do
    tier  = tier_for(conn.request_path)
    limit = @limits[tier]
    key   = bucket_key(conn, tier)

    case Hammer.check_rate(key, @scale_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "Too many requests"}))
        |> halt()
    end
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp tier_for(path) do
    cond do
      String.starts_with?(path, "/auth") ->
        :auth

      Enum.any?(@upload_paths, &String.starts_with?(path, &1)) ->
        :upload

      String.starts_with?(path, "/sessions/") and Enum.any?(@poll_suffixes, &String.ends_with?(path, &1)) ->
        :poll

      true ->
        :general
    end
  end

  # `/auth` stays IP-keyed because there's no user_id yet — login is by
  # definition anonymous. Everything else prefers user_id, falling back
  # to IP when no valid token is present (e.g. unauthenticated GET to a
  # gated route — will 401 from the router anyway, rate-limit is belt-
  # and-suspenders).
  defp bucket_key(conn, :auth), do: "ip:#{client_ip(conn)}:auth"
  defp bucket_key(conn, tier) do
    case user_id_from_token(conn) do
      {:ok, uid} -> "user:#{uid}:#{tier}"
      :none      -> "ip:#{client_ip(conn)}:#{tier}"
    end
  end

  # Cheap indexed JOIN on (auth_tokens, users) — typically < 1 ms. If
  # this ever becomes a bottleneck, cache token → user_id in an ETS
  # table with a short TTL.
  defp user_id_from_token(conn) do
    with [header | _]   <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- String.trim(header),
         {:ok, uid} <- lookup_user_id(token) do
      {:ok, uid}
    else
      _ -> :none
    end
  end

  defp lookup_user_id(token) do
    try do
      # auth_tokens stores sha256(token); hash before lookup. Same
      # contract as `AuthPlug.get_auth_user`.
      token_hash = DmhAi.AuthPlug.hash_token(token)

      result = query!(Repo, """
      SELECT u.id
      FROM auth_tokens t
      JOIN users u ON t.user_id = u.id
      WHERE t.token_hash = ? AND u.deleted = 0
      """, [token_hash])

      case result.rows do
        [[uid]] -> {:ok, uid}
        _       -> :none
      end
    rescue
      _ -> :none
    end
  end

  # Resolve the IP to bucket on. Three cases — each is the right
  # answer to a different threat model:
  #
  # 1. `remote_ip` is non-loopback → use it directly. The immediate
  #    caller IS the origin; any `X-Forwarded-For` is caller-supplied
  #    and trivially spoofable. Trusting it would let a public
  #    attacker bypass per-IP rate-limit by rotating X-F-F values.
  #
  # 2. `remote_ip` is loopback AND X-F-F is present → use the LAST
  #    entry of X-F-F. This is the deploy-behind-nginx case: the
  #    proxy appends to X-F-F as it forwards (`proxy_set_header
  #    X-Forwarded-For $proxy_add_x_forwarded_for;`), so the
  #    rightmost token is what nginx itself wrote, which is the IP
  #    of the actual public client (or the closest upstream proxy).
  #    Without this, every public request behind nginx shares one
  #    `127.0.0.1` bucket — a single brute-forcer DoSes legitimate
  #    logins for everyone.
  #
  # 3. `remote_ip` is loopback AND X-F-F is absent → use
  #    `127.0.0.1`. Operator-on-host-shell traffic; a single bucket
  #    is fine because the operator isn't the attacker.
  #
  # Asymmetric to `router.ex:client_ip/1`, which is intentionally
  # permissive (UI hint, never security). This helper is the
  # security-correct mirror image.
  defp client_ip(conn) do
    if loopback_remote?(conn.remote_ip) do
      case get_req_header(conn, "x-forwarded-for") do
        [xff | _] when xff != "" ->
          xff |> String.split(",") |> List.last() |> String.trim()

        _ ->
          conn.remote_ip |> :inet.ntoa() |> to_string()
      end
    else
      conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp loopback_remote?({127, _, _, _}),           do: true
  defp loopback_remote?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_remote?(_),                         do: false
end
