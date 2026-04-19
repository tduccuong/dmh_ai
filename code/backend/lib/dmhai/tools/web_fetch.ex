# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.WebFetch do
  @moduledoc """
  Worker tool wrapper around `Dmhai.Web.Fetcher`. CMP-aware — if the
  primary response is a GDPR consent wall, transparently tries AMP
  variants and then archive mirrors.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Web.Fetcher

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description,
    do:
      "Fetch and read the text content of a URL. Falls back to AMP/archive mirrors for paywalled pages."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "The full URL to fetch (must start with http:// or https://)."
          }
        },
        required: ["url"]
      }
    }
  end

  @impl true
  def execute(%{"url" => url}, _context) when is_binary(url) do
    case Fetcher.fetch(url) do
      {:ok, %{content: content} = result} ->
        {:ok, %{
          url:       result.url,
          final_url: result.final_url,
          title:     result.title,
          content:   content,
          truncated: result.truncated,
          source:    result.source,   # :direct | :amp_or_mirror | :archive_today | :wayback
          cmp:       result.cmp,      # nil | :onetrust | :sourcepoint | …
          tried:     result.tried
        }}

      {:error, {:cmp_wall, u, cmp: vendor, tried: tried}} ->
        {:error, "GDPR/CMP wall (#{vendor}) for #{u}. Tried fallbacks: #{inspect(tried)}. " <>
                 "Consider using web_search for a snippet instead."}

      {:error, {:fetch_failed, reason, u, tried}} ->
        {:error, "Fetch failed for #{u}: #{inspect(reason)}. Tried: #{inspect(tried)}."}

      {:error, {:invalid_url, u}} ->
        {:error, "Invalid URL: #{inspect(u)}. Must start with http:// or https://."}

      {:error, reason} ->
        {:error, "Fetch failed: #{inspect(reason)}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: url"}
end
