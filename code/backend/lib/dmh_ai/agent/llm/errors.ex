# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.LLM.Errors do
  @moduledoc """
  Error-shape helpers shared by the call + stream paths in
  `DmhAi.Agent.LLM`. Pure functions over response structs and free
  text — no I/O, no state.

    * `rate_limited_error/1` — extract a typed rate-limit tuple from
      a Req response, preferring a server-supplied `Retry-After`.
    * `parse_retry_after_ms/1` — parse the `retry-after` header
      (integer seconds only) into milliseconds.
    * `looks_like_rate_limit?/1` — substring match against known
      rate-limit markers (rate limit / quota / throttle / …).
    * `looks_like_server_error?/1` — substring match against known
      transient-overload markers (overloaded / 502 / 503 / 504 / …).
  """

  # Extract a rate-limit error tuple, preferring a server-supplied
  # `Retry-After` header when present so we can throttle exactly as
  # long as the provider asked us to — not a blanket constant. Falls
  # back to `:rate_limited` atom (caller uses the configurable
  # default from `AgentSettings.rate_limit_throttle_secs/0`).
  def rate_limited_error(%_{headers: headers}) do
    case parse_retry_after_ms(headers) do
      nil -> {:error, :rate_limited}
      ms  -> {:error, {:rate_limited, ms}}
    end
  end
  def rate_limited_error(_), do: {:error, :rate_limited}

  # Parse `Retry-After` from Req's `headers` map (string keys →
  # list-of-string values). Supports the integer-seconds form only
  # (e.g. `"30"`, `"120"`). HTTP-date form (`"Wed, 21 Oct 2015
  # 07:28:00 GMT"`) and malformed values return nil — caller falls
  # back to the configured default.
  def parse_retry_after_ms(%{} = headers) do
    # Req normalises header names to lowercase.
    case Map.get(headers, "retry-after") do
      [value | _] when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {secs, ""} when secs > 0 and secs <= 3600 -> secs * 1000
          _                                         -> nil
        end

      _ -> nil
    end
  end
  def parse_retry_after_ms(_), do: nil

  # Conservative rate-limit marker check. Upstreams vary: Ollama cloud
  # says "rate limit" / "too many requests"; OpenAI says "rate limit
  # reached" / "Too Many Requests"; Anthropic says "rate_limit_error"
  # or "quota". Match on lowercased substring so a surprising casing
  # doesn't slip past. Anything that matches NONE of these markers is
  # treated as an unknown error and propagates up WITHOUT throttling
  # the account — rotating keys doesn't fix a malformed request.
  @rate_limit_markers [
    "rate limit", "rate_limit", "rate-limit",
    "too many requests",
    "quota", "throttle", "slow down", "try again in"
  ]

  def looks_like_rate_limit?(text) when is_binary(text) do
    lower = String.downcase(text)
    Enum.any?(@rate_limit_markers, &String.contains?(lower, &1))
  end
  def looks_like_rate_limit?(_), do: false

  # Transient server-overload markers that arrive as inline NDJSON
  # errors. Distinct from rate-limit markers — these mean "upstream
  # is fine, just try again", not "this account hit a quota".
  @server_error_markers [
    "overloaded", "service unavailable", "temporarily unavailable",
    "internal server error", "internal error",
    "retry shortly", "try again shortly",
    "503", "502", "504"
  ]

  def looks_like_server_error?(text) when is_binary(text) do
    lower = String.downcase(text)
    Enum.any?(@server_error_markers, &String.contains?(lower, &1))
  end
  def looks_like_server_error?(_), do: false
end
