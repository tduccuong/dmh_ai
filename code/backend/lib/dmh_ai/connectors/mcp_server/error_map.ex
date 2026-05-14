# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPServer.ErrorMap do
  @moduledoc """
  Generic HTTP-status → canonical error classifier for the
  MCPServer pipeline. Vendor-specific quirks (Google's
  `error.status` enum, HubSpot's `category`, etc.) are handled
  upstream in each connector's `remap_error/1`; this module is the
  last-resort generic fallback when the body shape doesn't match
  any known vendor envelope.

  Canonical atoms:

    * `:unauthorised` — 401 / 403
    * `:not_found` — 404
    * `:rate_limited` — 429
    * `:duplicate` — 409
    * `:invalid_request` — 400 / 422
    * `:upstream_5xx` — 500+
    * `:upstream_other` — anything else non-2xx

  Returned as `{:error, atom}`; the MCPServer wraps that in an
  MCP JSON-RPC error envelope.
  """

  @spec classify(non_neg_integer(), term()) :: atom()
  def classify(status, _body) do
    cond do
      status == 400 -> :invalid_request
      status == 401 -> :unauthorised
      status == 403 -> :unauthorised
      status == 404 -> :not_found
      status == 409 -> :duplicate
      status == 422 -> :invalid_request
      status == 429 -> :rate_limited
      status in 500..599 -> :upstream_5xx
      true -> :upstream_other
    end
  end
end
