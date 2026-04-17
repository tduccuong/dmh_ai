# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Util.Url do
  @moduledoc """
  URL manipulation helpers used across the web fetch / search pipeline.
  """

  @doc "Parse a URL string into a %URI{}; returns nil on malformed input."
  @spec parse(String.t()) :: URI.t() | nil
  def parse(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = u when scheme in ["http", "https"] and is_binary(host) -> u
      _ -> nil
    end
  end
  def parse(_), do: nil

  @doc """
  Normalise a URL: lowercase scheme/host, strip trailing slash (except for bare roots),
  drop fragments. Returns a normalised string or nil on parse failure.
  """
  @spec normalise(String.t()) :: String.t() | nil
  def normalise(url) do
    case parse(url) do
      nil -> nil
      uri ->
        path =
          case uri.path do
            nil -> ""
            "/" -> "/"
            p -> String.trim_trailing(p, "/")
          end

        %URI{uri | scheme: String.downcase(uri.scheme),
                   host: String.downcase(uri.host),
                   path: path,
                   fragment: nil}
        |> URI.to_string()
    end
  end

  @doc """
  Replace the host portion of a URL, preserving scheme/path/query/fragment.
  Used to construct `m.example.com` / `amp.example.com` variants.
  """
  @spec with_host(String.t(), String.t()) :: String.t() | nil
  def with_host(url, new_host) when is_binary(new_host) do
    case parse(url) do
      nil -> nil
      uri -> URI.to_string(%URI{uri | host: new_host})
    end
  end

  @doc """
  Prepend a path segment to the URL path. Preserves query/fragment.
  Examples: prepend_path("https://x.com/foo", "amp") → "https://x.com/amp/foo"
  """
  @spec prepend_path(String.t(), String.t()) :: String.t() | nil
  def prepend_path(url, prefix) when is_binary(prefix) do
    case parse(url) do
      nil -> nil
      uri ->
        cleaned = String.trim_leading(prefix, "/")
        new_path =
          case uri.path do
            nil -> "/" <> cleaned
            "/" -> "/" <> cleaned <> "/"
            p   -> "/" <> cleaned <> p
          end
        URI.to_string(%URI{uri | path: new_path})
    end
  end

  @doc """
  Append a path segment to the URL path (before the query string).
  Examples: append_path("https://x.com/foo", "amp") → "https://x.com/foo/amp"
  """
  @spec append_path(String.t(), String.t()) :: String.t() | nil
  def append_path(url, suffix) when is_binary(suffix) do
    case parse(url) do
      nil -> nil
      uri ->
        cleaned = String.trim_trailing(suffix, "/")
        base_path =
          case uri.path do
            nil -> ""
            p   -> String.trim_trailing(p, "/")
          end
        URI.to_string(%URI{uri | path: base_path <> "/" <> cleaned})
    end
  end

  @doc """
  Merge query params into the URL's existing query string. Overwrites duplicates.
  """
  @spec with_query(String.t(), map() | keyword()) :: String.t() | nil
  def with_query(url, params) when is_map(params) or is_list(params) do
    case parse(url) do
      nil -> nil
      uri ->
        existing = URI.decode_query(uri.query || "")
        merged   = Map.merge(existing, Map.new(params, fn {k, v} -> {to_string(k), to_string(v)} end))
        URI.to_string(%URI{uri | query: URI.encode_query(merged)})
    end
  end

  @doc """
  Return the registered host (drops a leading `www.`). `nil` for malformed URLs.
  """
  @spec bare_host(String.t()) :: String.t() | nil
  def bare_host(url) do
    case parse(url) do
      nil -> nil
      %URI{host: host} -> String.replace_prefix(host, "www.", "")
    end
  end
end
