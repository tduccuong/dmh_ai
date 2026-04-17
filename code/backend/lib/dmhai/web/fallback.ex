# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Web.Fallback do
  @moduledoc """
  Alternative URLs to try when the primary fetch hits a CMP wall.

  `amp_variants/1` — common AMP path/subdomain patterns (news sites).
  `archive_mirrors/1` — archive.today and Wayback Machine URLs.
  `all_variants/1`  — amp variants followed by archive mirrors.

  All functions are pure; the caller issues the actual HTTP requests.
  """

  alias Dmhai.Util.Url

  @doc """
  AMP variants for a URL. Returns deduped, normalised candidates.
  """
  @spec amp_variants(String.t()) :: [String.t()]
  def amp_variants(url) when is_binary(url) do
    case Url.parse(url) do
      nil -> []
      uri ->
        host = uri.host

        variants = [
          # /amp/<path>
          Url.prepend_path(url, "amp"),

          # <path>/amp
          Url.append_path(url, "amp"),

          # <path>.amp
          amp_suffix(url),

          # ?output=amp
          Url.with_query(url, %{output: "amp"}),

          # m.example.com (mobile variant — often CMP-lighter)
          mobile_host(url, host),

          # amp.example.com
          if(not String.starts_with?(host, "amp."),
            do: Url.with_host(url, "amp." <> strip_www(host)),
            else: nil)
        ]

        variants
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  def amp_variants(_), do: []

  @doc """
  Archive mirror URLs. Wayback Machine + archive.today. Ordered by typical latency.
  """
  @spec archive_mirrors(String.t()) :: [String.t()]
  def archive_mirrors(url) when is_binary(url) do
    case Url.normalise(url) do
      nil -> []
      normalised ->
        [
          # archive.today's `newest` capture redirect
          "https://archive.ph/newest/" <> normalised,
          # Wayback Machine latest snapshot
          "https://web.archive.org/web/2024/" <> normalised
        ]
    end
  end

  def archive_mirrors(_), do: []

  @doc "AMP variants then archive mirrors, in order."
  @spec all_variants(String.t()) :: [String.t()]
  def all_variants(url), do: amp_variants(url) ++ archive_mirrors(url)

  # ── private ─────────────────────────────────────────────────────────────

  defp amp_suffix(url) do
    case Url.parse(url) do
      nil -> nil
      %URI{path: path} = uri when is_binary(path) ->
        # <path>.html → <path>.amp.html  ;  <path> → <path>.amp
        new_path =
          cond do
            String.ends_with?(path, ".html") -> String.replace_suffix(path, ".html", ".amp.html")
            path == "" or path == "/"        -> "/.amp"
            true                              -> path <> ".amp"
          end
        URI.to_string(%URI{uri | path: new_path})
      _ -> nil
    end
  end

  defp mobile_host(url, host) do
    cond do
      String.starts_with?(host, "m.") -> nil
      String.starts_with?(host, "www.") ->
        Url.with_host(url, "m." <> String.trim_leading(host, "www."))
      true ->
        Url.with_host(url, "m." <> host)
    end
  end

  defp strip_www(host), do: String.replace_prefix(host, "www.", "")
end
