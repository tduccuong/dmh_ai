# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Ingest.SourceId do
  @moduledoc """
  Normalised stable identifiers per source type, per Primitive 0.2.

  Two ingests of the same logical source must hash to the same
  `source_id` so the idempotence gate (sha256 of bytes) actually
  fires. The most common bug is URL drift: `example.com/page` and
  `example.com/page?utm_source=newsletter` are the same source from
  the user's perspective. Normalisation is the single place we
  collapse those.

  | Source type        | source_id derivation                          |
  |--------------------|-----------------------------------------------|
  | `"url"`            | normalised URL (lowercased host, no fragment, |
  |                    | stripped common tracking params)              |
  | `"file"`           | sha256(org_id ‖ user-supplied path)           |
  | `"folder"`         | the connector-uri unchanged                   |
  | `"text"`           | sha256(org_id ‖ user-supplied title or body)  |
  | `"connector"`      | the connector-uri unchanged                   |
  """

  @doc """
  Derive the canonical `source_id` from `(source_kind, source_ref, org_id)`.
  """
  @spec derive(String.t(), String.t(), String.t()) :: String.t()
  def derive("url", source_ref, _org_id) when is_binary(source_ref) do
    normalize_url(source_ref)
  end

  def derive("file", source_ref, org_id) when is_binary(source_ref) and is_binary(org_id) do
    sha256(org_id <> "\0" <> source_ref)
  end

  def derive("folder", source_ref, _org_id) when is_binary(source_ref) do
    source_ref
  end

  def derive("connector", source_ref, _org_id) when is_binary(source_ref) do
    source_ref
  end

  def derive("text", source_ref, org_id) when is_binary(source_ref) and is_binary(org_id) do
    sha256(org_id <> "\0" <> source_ref)
  end

  # Unknown source kinds — hash the input so we still get a stable
  # identifier; logged so we notice if a new kind needs explicit
  # handling.
  def derive(other, source_ref, org_id) do
    require Logger
    Logger.warning("[Ingest.SourceId] unknown source_kind=#{inspect(other)} — hashing source_ref")
    sha256(org_id <> "\0" <> to_string(source_kind_string(other)) <> "\0" <> to_string(source_ref))
  end

  defp source_kind_string(k) when is_binary(k), do: k
  defp source_kind_string(k), do: inspect(k)

  @doc """
  URL normaliser. Lower-case the host, strip the fragment, drop a
  curated list of tracking params, collapse the path's trailing
  slash. Pure function — call directly when you need to dedupe a
  URL outside the ingest pipeline.
  """
  @spec normalize_url(String.t()) :: String.t()
  def normalize_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        uri = %URI{URI.parse(url) | host: String.downcase(host), fragment: nil}
        uri = %URI{uri | query: strip_tracking_params(uri.query)}
        uri = %URI{uri | path: normalize_path(uri.path)}
        URI.to_string(uri)

      _ ->
        url
    end
  end

  # Tracking-param tokens we always drop. Conservative set — only
  # widely-known marketing params. Real-world URLs accumulate dozens
  # more (`fbclid`, `gclid`, etc.) but those vary by ecosystem; this
  # is the safe baseline.
  @tracking_params ~w(utm_source utm_medium utm_campaign utm_term utm_content
                      fbclid gclid msclkid mc_cid mc_eid
                      ref ref_src refsrc)

  defp strip_tracking_params(nil), do: nil
  defp strip_tracking_params(""), do: nil

  defp strip_tracking_params(query) do
    query
    |> URI.decode_query()
    |> Enum.reject(fn {k, _v} -> k in @tracking_params end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> URI.encode_query()
    |> case do
      "" -> nil
      q -> q
    end
  end

  # Collapse a trailing slash on non-root paths. `/foo/` and `/foo`
  # normalise to `/foo`; `/` stays as `/`.
  defp normalize_path(nil), do: nil
  defp normalize_path("/"), do: "/"

  defp normalize_path(path) when is_binary(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      stripped -> stripped
    end
  end

  defp sha256(s) when is_binary(s),
    do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
end
