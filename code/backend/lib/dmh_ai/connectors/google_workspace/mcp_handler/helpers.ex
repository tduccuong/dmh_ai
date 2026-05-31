# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Helpers do
  @moduledoc """
  Cross-surface helpers shared between the Google Workspace
  MCPHandler sub-modules (Gmail, Gcal, Drive, Sheets, Docs, ...).

  Anything used by exactly one surface lives in that surface's
  module; everything here is touched by ≥2 surfaces.
  """

  alias DmhAi.Connectors.MCPServer.RestBridge

  # Whitelist for ids that get interpolated into URL segments. Gmail
  # message ids, Drive file ids, Calendar event ids and Google Sheet
  # ids are all `[A-Za-z0-9_-]+`; Calendar-default `primary` falls
  # under the same charset.
  @path_id_re ~r/^[A-Za-z0-9_-]+$/

  @doc """
  Whitelist a value that's about to be interpolated into a URL
  segment. Raises `ArgumentError` for anything containing characters
  outside `[A-Za-z0-9_-]` — the dispatcher surfaces the raise as an
  error envelope rather than building a URL with an injected path.
  """
  def safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid google_workspace path id: #{inspect(id)}"
    end
  end

  @doc """
  Attach a `Bearer` `authorization` header to a Req-style opts
  keyword list when the ctx carries a token.
  """
  def with_bearer(opts, ctx) do
    case Map.get(ctx, :bearer_token) do
      t when is_binary(t) and t != "" ->
        headers = Keyword.get(opts, :headers, [])
        Keyword.put(opts, :headers, [{"authorization", "Bearer " <> t} | headers])
      _ ->
        opts
    end
  end

  # HTTP sub-calls go through RestBridge helpers so the test stub
  # (`:__rest_bridge_http_stub__`) intercepts every outbound request
  # from a handler — both FunctionSpec-driven functions AND the
  # custom-handler fan-outs / multipart uploads.

  @doc "RestBridge-routed GET, returns the decoded body on 2xx."
  def bare_get(url, query, ctx), do: RestBridge.simple_get(url, query, ctx)

  @doc "RestBridge-routed POST with JSON body, returns the decoded body on 2xx."
  def bare_post(url, json_body, ctx), do: RestBridge.simple_post(url, json_body, ctx)
end
