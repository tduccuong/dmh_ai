# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPServer.ErrorMap do
  @moduledoc """
  Generic HTTP-status → canonical error classifier for the
  MCPServer pipeline. Returns a struct carrying:

    * `:class` — the canonical atom (was the only output of the
       legacy function). Values: `:unauthorised`, `:forbidden`,
       `:api_disabled`, `:not_found`, `:rate_limited`,
       `:duplicate`, `:invalid_request`, `:upstream_5xx`,
       `:upstream_other`.

    * `:vendor_message` — the vendor's own error description from
       the response body when present. Helps the model tell the
       user honestly *"Google says: …"* instead of inventing.

    * `:vendor_hint_url` — actionable URL the vendor embeds in the
       error body (e.g. Google's *"Enable it by visiting <url>"*
       URL for "API not enabled" 403s). The model can relay this
       to the user as a clickable link to self-serve the fix.

  Vendor-specific quirks (Google's `error.status` enum, HubSpot's
  `category`, etc.) are handled upstream in each connector's
  `remap_error/1`; this module is the last-resort generic
  fallback when the body shape doesn't match any known vendor
  envelope. 403 specifically gets a body-peek to distinguish the
  many shapes ("API not enabled", "insufficient permissions",
  "billing required", "user disabled") that today's deployments
  all map to a single misleading `:unauthorised`.

  Returned as `{:error, %ErrorMap{}}`; the MCPServer wraps that
  in an MCP JSON-RPC error envelope.
  """

  defstruct [:class, :vendor_message, :vendor_hint_url]

  @type class ::
          :unauthorised | :forbidden | :api_disabled | :not_found
          | :rate_limited | :duplicate | :invalid_request
          | :upstream_5xx | :upstream_other

  @type t :: %__MODULE__{
          class:           class(),
          vendor_message:  String.t() | nil,
          vendor_hint_url: String.t() | nil
        }

  @spec classify(non_neg_integer(), term()) :: t()
  def classify(status, body) do
    case status do
      401 -> %__MODULE__{class: :unauthorised, vendor_message: vendor_message(body)}
      403 -> classify_403(body)
      400 -> %__MODULE__{class: :invalid_request, vendor_message: vendor_message(body)}
      404 -> %__MODULE__{class: :not_found, vendor_message: vendor_message(body)}
      409 -> %__MODULE__{class: :duplicate, vendor_message: vendor_message(body)}
      422 -> %__MODULE__{class: :invalid_request, vendor_message: vendor_message(body)}
      429 -> %__MODULE__{class: :rate_limited, vendor_message: vendor_message(body)}
      s when s in 500..599 -> %__MODULE__{class: :upstream_5xx, vendor_message: vendor_message(body)}
      _   -> %__MODULE__{class: :upstream_other, vendor_message: vendor_message(body)}
    end
  end

  # 403 has many flavours. Read the body's message for actionable
  # signals; the most common one Google emits is "API has not been
  # used in project N" with an embedded "Enable it by visiting…"
  # URL — that one's worth a dedicated `:api_disabled` class so the
  # admin/user can self-serve the fix in one click.
  defp classify_403(body) do
    msg = vendor_message(body)

    cond do
      is_binary(msg) and msg =~ ~r/API has not been used|API is disabled|enable it by visiting/i ->
        %__MODULE__{
          class:           :api_disabled,
          vendor_message:  msg,
          vendor_hint_url: extract_first_url(msg)
        }

      true ->
        %__MODULE__{class: :forbidden, vendor_message: msg}
    end
  end

  # Pull a useful vendor error string out of common body shapes.
  # Handles Google's `{"error": {"message": "..."}}`, plain
  # `{"error": "..."}` / `{"message": "..."}`, and a few REST
  # variants. Returns nil when no recognisable string surfaces.
  defp vendor_message(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  defp vendor_message(%{"error" => e}) when is_binary(e), do: e
  defp vendor_message(%{"message" => m}) when is_binary(m), do: m
  defp vendor_message(%{"detail"  => d}) when is_binary(d), do: d
  defp vendor_message(_), do: nil

  defp extract_first_url(text) when is_binary(text) do
    case Regex.run(~r/https?:\/\/[^\s,)\]<]+/u, text) do
      [url | _] -> url
      _          -> nil
    end
  end

  defp extract_first_url(_), do: nil
end
