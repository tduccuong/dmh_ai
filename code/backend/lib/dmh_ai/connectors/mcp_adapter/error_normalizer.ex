# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPAdapter.ErrorNormalizer do
  @moduledoc """
  Maps vendor-specific error terms to the canonical vocabulary the
  Primitive 0.3 manifest contract declares:

      :unauthorised  | :not_found | :rate_limited | :duplicate | :upstream_5xx

  Two-stage normalisation:

    1. Connector's optional `remap_error/1` callback gets first crack.
       It returns either a canonical atom (override) or `:passthrough`.
    2. Generic patterns: HTTP status codes, `Req` failures, `:timeout`,
       MCP-shaped JSON-RPC errors. Anything we can't recognise falls
       through as `:upstream_5xx` so the calling task sees SOMETHING
       structured.
  """

  @doc """
  Normalize an error to a canonical envelope map suitable for
  surfacing to the model.
  """
  @spec normalize(term(), (term() -> atom() | :passthrough)) :: map()
  def normalize(reason, remap_fn) when is_function(remap_fn, 1) do
    case remap_fn.(reason) do
      atom when is_atom(atom) and atom != :passthrough ->
        envelope(atom, reason)

      _ ->
        envelope(generic_classify(reason), reason)
    end
  end

  defp generic_classify({:http, 401, _}), do: :unauthorised
  defp generic_classify({:http, 403, _}), do: :unauthorised
  defp generic_classify({:http, 404, _}), do: :not_found
  defp generic_classify({:http, 409, _}), do: :duplicate
  defp generic_classify({:http, 429, _}), do: :rate_limited
  defp generic_classify({:http, s, _}) when is_integer(s) and s >= 500, do: :upstream_5xx
  defp generic_classify(:timeout),                                       do: :upstream_5xx
  defp generic_classify(:not_implemented),                               do: :not_implemented
  defp generic_classify(%{"code" => -32601}),                            do: :not_found
  defp generic_classify(%{"code" => code}) when is_integer(code) and code < 0, do: :upstream_5xx
  defp generic_classify(_),                                              do: :upstream_5xx

  defp envelope(:unauthorised,  _r), do: %{error: "unauthorised"}
  defp envelope(:not_found,     _r), do: %{error: "not_found"}
  defp envelope(:rate_limited,  _r), do: %{error: "rate_limited"}
  defp envelope(:duplicate,     _r), do: %{error: "duplicate"}
  defp envelope(:upstream_5xx,   r), do: %{error: "upstream_5xx", detail: inspect_short(r)}
  defp envelope(:not_implemented, _), do: %{error: "not_implemented"}
  defp envelope(other,           r), do: %{error: to_string(other), detail: inspect_short(r)}

  defp inspect_short(v), do: v |> inspect() |> String.slice(0, 120)
end
