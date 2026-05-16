# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPAdapter.ErrorNormalizer do
  @moduledoc """
  Maps vendor-specific error terms to the canonical vocabulary the
  Primitive 0.3 manifest contract declares:

      :unauthorised | :forbidden | :api_disabled | :not_found
      | :rate_limited | :duplicate | :invalid_request
      | :upstream_5xx | :not_implemented

  Two-stage normalisation:

    1. Connector's optional `remap_error/1` callback gets first crack.
       It returns either a canonical atom (override) or `:passthrough`.
    2. Generic patterns: HTTP status codes, `Req` failures, `:timeout`,
       MCP-shaped JSON-RPC errors, `ErrorMap` structs. Anything we
       can't recognise falls through as `:upstream_5xx` so the
       calling task sees SOMETHING structured.

  Beyond the class atom, the envelope can carry vendor detail:

    * `:vendor_message` — vendor's own error string (e.g. *"Gmail
       API has not been used in project 352…"*).
    * `:vendor_hint_url` — actionable URL the vendor embeds in
       its body (e.g. *"Enable it by visiting <url>"*). The model
       relays this to the user as a clickable link.

  The fields source from either:
    * An `ErrorMap` struct returned by `RestBridge.invoke/3` (for
      in-process MCP), or
    * The `data` field of an MCP JSON-RPC error (which our
      `MCPServer.Plug.error_envelope_from_map/2` populates from
      the same ErrorMap struct so both paths surface identical
      detail).
  """

  alias DmhAi.Connectors.MCPServer.ErrorMap

  @doc """
  Normalize an error to a canonical envelope map suitable for
  surfacing to the model.
  """
  @spec normalize(term(), (term() -> atom() | :passthrough)) :: map()
  def normalize(reason, remap_fn) when is_function(remap_fn, 1) do
    {class, detail} = classify_with_detail(reason, remap_fn)
    envelope(class, reason, detail)
  end

  # remap_error/1 gets the FULL reason (including any structured
  # data). If it returns a non-passthrough atom, the connector has
  # overridden — use that class, but still pull vendor_detail from
  # the original reason since the connector's remap doesn't surface
  # it. If passthrough, run generic classification.
  defp classify_with_detail(reason, remap_fn) do
    case remap_fn.(reason) do
      atom when is_atom(atom) and atom != :passthrough ->
        {atom, vendor_detail(reason)}

      _ ->
        {generic_classify(reason), vendor_detail(reason)}
    end
  end

  # ── classification ────────────────────────────────────────────────

  defp generic_classify({:http, 401, _}), do: :unauthorised
  defp generic_classify({:http, 403, _}), do: :forbidden
  defp generic_classify({:http, 404, _}), do: :not_found
  defp generic_classify({:http, 409, _}), do: :duplicate
  defp generic_classify({:http, 429, _}), do: :rate_limited
  defp generic_classify({:http, s, _}) when is_integer(s) and s >= 500, do: :upstream_5xx
  defp generic_classify(:timeout),                                       do: :upstream_5xx
  defp generic_classify(:not_implemented),                               do: :not_implemented
  defp generic_classify(%ErrorMap{class: class}),                        do: class

  # JSON-RPC errors from MCPServer.Plug — the `data.class` field
  # was set when MCPServer wrapped an ErrorMap. Fall back to the
  # code-based heuristic when `data` isn't present.
  defp generic_classify({:rpc, %{"data" => %{"class" => class_str}}}) when is_binary(class_str) do
    case class_str do
      "unauthorised"     -> :unauthorised
      "forbidden"        -> :forbidden
      "api_disabled"     -> :api_disabled
      "not_found"        -> :not_found
      "rate_limited"     -> :rate_limited
      "duplicate"        -> :duplicate
      "invalid_request"  -> :invalid_request
      "upstream_5xx"     -> :upstream_5xx
      _                   -> :upstream_5xx
    end
  end

  defp generic_classify({:rpc, %{"code" => -32601}}),                    do: :not_found
  defp generic_classify({:rpc, %{"code" => code}}) when is_integer(code) and code < 0, do: :upstream_5xx
  defp generic_classify(%{"code" => -32601}),                            do: :not_found
  defp generic_classify(%{"code" => code}) when is_integer(code) and code < 0, do: :upstream_5xx
  defp generic_classify(_),                                              do: :upstream_5xx

  # ── vendor detail extraction ──────────────────────────────────────

  defp vendor_detail(%ErrorMap{vendor_message: m, vendor_hint_url: u}),
    do: %{vendor_message: m, vendor_hint_url: u}

  defp vendor_detail({:rpc, %{"data" => data}}) when is_map(data) do
    %{
      vendor_message:  Map.get(data, "vendor_message"),
      vendor_hint_url: Map.get(data, "vendor_hint_url")
    }
  end

  defp vendor_detail({:rpc, %{"message" => m}}) when is_binary(m),
    do: %{vendor_message: m, vendor_hint_url: nil}

  defp vendor_detail(_), do: %{vendor_message: nil, vendor_hint_url: nil}

  # ── envelope construction ─────────────────────────────────────────

  defp envelope(class, reason, %{vendor_message: m, vendor_hint_url: u}) do
    base = %{error: Atom.to_string(class)}

    base
    |> maybe_put(:vendor_message,  m)
    |> maybe_put(:vendor_hint_url, u)
    |> maybe_attach_detail(class, reason)
    |> maybe_attach_hint(class, u)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""),  do: map
  defp maybe_put(map, key, val),  do: Map.put(map, key, val)

  # `:upstream_5xx` and `:upstream_other` keep their raw-reason
  # `:detail` so the model can quote the underlying transport
  # error verbatim when a classification doesn't fit. Other
  # classes already have a clear meaning.
  defp maybe_attach_detail(map, :upstream_5xx,   r), do: Map.put(map, :detail, inspect_short(r))
  defp maybe_attach_detail(map, :upstream_other, r), do: Map.put(map, :detail, inspect_short(r))
  defp maybe_attach_detail(map, _class, _r),         do: map

  # `:api_disabled` is the actionable shape — embed a structured
  # hint the model can relay to the user verbatim. The vendor's
  # actionable URL is already in `:vendor_hint_url`; the hint
  # phrases the call-to-action so the model doesn't have to.
  defp maybe_attach_hint(map, :api_disabled, url) when is_binary(url) and url != "" do
    Map.put(
      map,
      :hint,
      "The vendor's API isn't enabled for this deployment. Ask the user (or their admin) to enable it by visiting: #{url}"
    )
  end

  defp maybe_attach_hint(map, _class, _u), do: map

  defp inspect_short(v), do: v |> inspect() |> String.slice(0, 200)
end
