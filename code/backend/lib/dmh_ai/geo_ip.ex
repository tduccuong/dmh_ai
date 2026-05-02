# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.GeoIP do
  @moduledoc """
  IP-to-language hint via the free `ipapi.co/<ip>/country/` endpoint,
  with an in-memory ETS hot cache to keep external calls infrequent
  (the free tier allows ~1 000 requests/day, which is fine when each
  unique IP is looked up at most once per `@ttl_ms`).

  Used by `GET /detect-lang` as the third tier of the FE language
  fallback chain (localStorage → navigator.languages → IP → 'en').
  Best-effort: any failure (network, unsupported country, malformed
  response, missing IP) returns nil, and the FE simply keeps its
  current default.

  Cache: ETS set, keyed by IP string. Value `{lang_or_nil, expiry_ms}`.
  Stale entries are evicted lazily on next lookup; no background
  sweeper. Negative results (unsupported country / API error) are
  cached too — that's the whole point of avoiding repeated external
  calls for IPs we already know don't map to a UI language.
  """

  require Logger

  @table :dmh_ai_geoip_cache
  @ttl_ms 24 * 60 * 60 * 1000
  @http_timeout_ms 3_000

  # ISO-3166-1 alpha-2 → UI language. Limited to languages we ship.
  # Anything not listed falls through to nil (FE keeps default 'en').
  @country_to_lang %{
    "VN" => "vi",
    "DE" => "de", "AT" => "de",
    "FR" => "fr",
    "ES" => "es", "MX" => "es", "AR" => "es", "CO" => "es",
    "CL" => "es", "PE" => "es", "VE" => "es", "EC" => "es",
    "BO" => "es", "UY" => "es", "PY" => "es", "GT" => "es",
    "DO" => "es", "HN" => "es", "NI" => "es", "SV" => "es",
    "CR" => "es", "PA" => "es", "PR" => "es", "CU" => "es"
  }

  @doc "Initialise the cache table. Call once at app boot."
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok
      _ ->
        :ok
    end
  end

  @doc """
  Best-effort lookup: returns the UI language for `ip` (e.g. `"vi"`),
  or nil. Hits the cache first; on miss, calls the external API and
  caches the result (success or nil) for `@ttl_ms`.

  Loopback / RFC1918 / link-local IPs short-circuit to nil — geo
  lookup against them always fails, no point asking the API.
  """
  @spec lookup_lang(String.t() | nil) :: String.t() | nil
  def lookup_lang(nil), do: nil
  def lookup_lang(""), do: nil

  def lookup_lang(ip) when is_binary(ip) do
    if private_ip?(ip) do
      nil
    else
      now = System.os_time(:millisecond)

      case :ets.lookup(@table, ip) do
        [{^ip, lang, expiry}] when expiry > now ->
          lang

        _ ->
          lang = fetch_lang(ip)
          :ets.insert(@table, {ip, lang, now + @ttl_ms})
          lang
      end
    end
  rescue
    e ->
      Logger.debug("[GeoIP] lookup_lang/1 crashed: #{Exception.message(e)}")
      nil
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  # Loopback / RFC1918 / link-local. Geo lookup against these always
  # fails or returns the host's public-routed country (which isn't the
  # client's). Either way, useless — short-circuit.
  defp private_ip?(ip) do
    String.starts_with?(ip, "127.") or
      String.starts_with?(ip, "10.") or
      String.starts_with?(ip, "192.168.") or
      String.starts_with?(ip, "169.254.") or
      ip == "::1" or
      String.starts_with?(ip, "fe80:") or
      String.starts_with?(ip, "fc") or
      String.starts_with?(ip, "fd") or
      Regex.match?(~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./, ip)
  end

  defp fetch_lang(ip) do
    url = "https://ipapi.co/#{ip}/country/"

    case Req.get(url,
           receive_timeout: @http_timeout_ms,
           connect_options: [timeout: @http_timeout_ms],
           retry: false,
           finch: DmhAi.Finch
         ) do
      {:ok, %{status: 200, body: body}} ->
        body |> to_string() |> String.trim() |> String.upcase()
        |> then(&Map.get(@country_to_lang, &1))

      {:ok, %{status: status}} ->
        Logger.debug("[GeoIP] HTTP #{status} for #{ip}")
        nil

      {:error, reason} ->
        Logger.debug("[GeoIP] fetch failed for #{ip}: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.debug("[GeoIP] fetch_lang/1 crashed: #{Exception.message(e)}")
      nil
  end
end
