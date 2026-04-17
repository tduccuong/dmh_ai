# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Web.ReaderExtractor do
  @moduledoc """
  Readability-style main-content extraction.

  Strategy, in order:
    1. Semantic tags: `<article>`, `<main>`, `[role=main]`, `[itemprop=articleBody]`.
    2. Highest-density `<div>` / `<section>` fallback (most text, fewest links).
    3. Give up — caller falls back to the flat `Dmhai.Util.Html.html_to_text/1`.

  Returns `%{title, text, url}` or `nil`.
  """

  require Logger

  # Candidate root selectors, in preference order.
  @semantic_selectors [
    "article",
    "[itemprop=articleBody]",
    "[role=main]",
    "main",
    ".article-body",
    ".article__body",
    ".post-content",
    ".entry-content",
    "#content article"
  ]

  # Min chars below which we reject a candidate (too short to be the article).
  @min_content_chars 300

  @doc """
  Try to extract the main article from an HTML document.
  Returns `nil` on parse failure or if no good candidate is found.
  """
  @spec extract(binary(), String.t() | nil) :: map() | nil
  def extract(html, source_url \\ nil) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> strip_chrome()
        |> find_main(source_url)

      _ ->
        nil
    end
  end

  # ── private ─────────────────────────────────────────────────────────────

  # Strip chrome tags that would otherwise leak into density scoring.
  @chrome_tags ~w(script style noscript iframe nav header footer aside svg
                  form button figure figcaption)

  defp strip_chrome(doc) do
    Enum.reduce(@chrome_tags, doc, fn tag, acc ->
      Floki.filter_out(acc, tag)
    end)
  end

  defp find_main(doc, source_url) do
    title = extract_title(doc)

    text =
      try_semantic(doc) ||
      try_density(doc)

    if is_binary(text) and String.length(text) >= @min_content_chars do
      %{title: title, text: collapse_ws(text), url: source_url}
    else
      nil
    end
  end

  defp try_semantic(doc) do
    Enum.find_value(@semantic_selectors, fn selector ->
      case Floki.find(doc, selector) do
        [] -> nil
        nodes ->
          text = nodes |> Enum.map_join("\n\n", &Floki.text/1) |> String.trim()
          if String.length(text) >= @min_content_chars, do: text, else: nil
      end
    end)
  end

  # Density scoring: for each <div>/<section>, compute (text_length / link_text_length),
  # weighted by absolute text length. Pick the top-scoring node.
  defp try_density(doc) do
    candidates = Floki.find(doc, "div, section")

    case candidates do
      [] -> nil
      _  ->
        best =
          candidates
          |> Enum.map(fn node ->
            text     = Floki.text(node) |> String.trim()
            text_len = String.length(text)
            link_len =
              node
              |> Floki.find("a")
              |> Enum.map_join(&Floki.text/1)
              |> String.length()

            density =
              if text_len == 0, do: 0.0,
              else: (text_len - link_len) / text_len

            score = text_len * density
            {score, text_len, text}
          end)
          |> Enum.filter(fn {_, len, _} -> len >= @min_content_chars end)
          |> Enum.max_by(fn {score, _, _} -> score end, fn -> nil end)

        case best do
          {_, _, text} -> text
          _ -> nil
        end
    end
  end

  defp extract_title(doc) do
    # Prefer og:title / article h1; fall back to <title>.
    cond do
      title = attr_value(doc, ~s(meta[property="og:title"]), "content") -> title
      title = attr_value(doc, ~s(meta[name="twitter:title"]), "content") -> title
      title = first_text(doc, "article h1, main h1, h1") -> title
      title = first_text(doc, "title") -> title
      true -> nil
    end
  end

  defp attr_value(doc, selector, attr) do
    case Floki.find(doc, selector) do
      [] -> nil
      nodes ->
        nodes
        |> Enum.map(&Floki.attribute(&1, attr))
        |> List.flatten()
        |> Enum.find(fn v -> is_binary(v) and String.trim(v) != "" end)
    end
  end

  defp first_text(doc, selector) do
    case Floki.find(doc, selector) do
      [] -> nil
      [node | _] ->
        t = node |> Floki.text() |> String.trim()
        if t == "", do: nil, else: t
    end
  end

  defp collapse_ws(text) do
    text
    |> then(&Regex.replace(~r/[ \t]+/, &1, " "))
    |> then(&Regex.replace(~r/\n{3,}/, &1, "\n\n"))
    |> String.trim()
  end
end
