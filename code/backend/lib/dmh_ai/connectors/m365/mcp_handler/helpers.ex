# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Helpers do
  @moduledoc """
  Cross-surface helpers shared between the Microsoft 365 MCPHandler
  sub-modules (Mail, Cal, Files, Teams, Todo, Excel, OneNote,
  Contacts, Users).

  Anything used by exactly one surface lives in that surface's
  module; everything here is touched by ≥2 surfaces.
  """

  # Microsoft Graph identifiers used in URL path segments:
  #   * mailbox message ids — base64url, may include `=`/`-`/`_`
  #   * drive item ids       — base64url
  #   * To Do list / task ids — base64url
  #   * Teams channel ids    — `19:<base64>@thread.tacv2` (colons + `@`)
  # The whitelist accepts every shape Graph actually returns; anything
  # else raises, so the dispatcher surfaces an error envelope rather
  # than constructing a URL with an injected path segment.
  @path_id_re ~r/^[A-Za-z0-9_=:@.\-]+$/

  @graph_base "https://graph.microsoft.com/v1.0/me"
  @graph_root "https://graph.microsoft.com/v1.0"

  @doc "Base URL for `/me`-scoped Graph endpoints (mailbox, drive, calendar, ...)."
  def graph_base, do: @graph_base

  @doc "Root Graph URL — used for tenant-wide endpoints (/teams/{id}, /users/{key})."
  def graph_root, do: @graph_root

  @doc """
  Whitelist a value that's about to be interpolated into a URL
  segment. Raises `ArgumentError` for anything outside the Graph
  identifier charset — the dispatcher surfaces the raise as an
  error envelope rather than building a URL with an injected path.
  """
  def safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid m365 path id: #{inspect(id)}"
    end
  end

  @doc """
  Attach a `Bearer` `authorization` header to a Req-style opts
  keyword list when the ctx carries a token.
  """
  def with_bearer(opts, %{bearer_token: t}) when is_binary(t) and t != "" do
    headers = Keyword.get(opts, :headers, [])
    Keyword.put(opts, :headers, [{"authorization", "Bearer " <> t} | headers])
  end

  def with_bearer(opts, _), do: opts

  @doc "Put `{k, v}` into `map` only when `v` is non-nil."
  def maybe_put_kv(map, _k, nil), do: map
  def maybe_put_kv(map, k, v), do: Map.put(map, k, v)
end
