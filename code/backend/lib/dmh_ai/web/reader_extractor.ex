# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Web.ReaderExtractor do
  @moduledoc """
  Readability-style main-content extraction.

  Two entry points:

  - `extract/2` — general-purpose: strips chrome (script/style/nav/header/
    footer/aside/svg/form/button/figure/figcaption), then tries semantic
    anchors, then density scoring. Used by the ad-hoc `web_fetch` path.

  - `extract_for_kb/2` — tighter filter for **KB ingestion**, where the
    content is permanent + embedded so we cannot tolerate ad / cookie /
    boilerplate / comment-section pollution. Adds:
      * class/id pattern strip for ad / consent / popup / share /
        related / comments / newsletter widgets
      * hidden-element strip (`[hidden]`, `[aria-hidden=true]`,
        inline display:none)
      * dialog / modal strip
      * post-extract line filter: drop lines that are >80% link text

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

  @doc """
  KB-ingest variant. Same density approach as `extract/2`, plus a
  tighter junk filter (class/id patterns, hidden elements, dialogs)
  and a post-extract line filter that drops mostly-link rows.
  """
  @spec extract_for_kb(binary(), String.t() | nil) :: map() | nil
  def extract_for_kb(html, source_url \\ nil) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        case doc
             |> strip_chrome()
             |> strip_kb_junk()
             |> find_main(source_url) do
          %{text: text} = result when is_binary(text) ->
            cleaned = drop_link_heavy_lines(text)
            if String.length(cleaned) >= @min_content_chars,
              do: %{result | text: cleaned},
              else: nil

          _ -> nil
        end

      _ -> nil
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

  # Selectors removed in addition to chrome for KB ingest. Each entry
  # is a Floki/CSS selector — substring matches on `class` and `id`
  # (`[attr*=value]`) catch the long-enough discriminating patterns;
  # whole-word matches (`[attr~=value]`) catch the short ones (e.g.
  # bare class="ad") without colliding with words like "header".
  @kb_junk_selectors [
    # cookie / consent / GDPR
    "[class*=cookie]", "[id*=cookie]",
    "[class*=consent]", "[id*=consent]",
    "[class*=gdpr]", "[id*=gdpr]",
    # ads — `~=` for whole-word "ad"/"ads"; `*=` with hyphenated /
    # underscored fragments to catch `ad-slot-1`, `ad_unit_2`,
    # `header-ad`, `slot_ad` without false-positiving on "address",
    # "adobe", "adapter", etc.
    "[class*=advert]", "[id*=advert]",
    "[class*=sponsor]", "[id*=sponsor]",
    "[class*=promo]",
    "[class~=ad]", "[id~=ad]", "[class~=ads]",
    "[class*=ad-]", "[id*=ad-]",
    "[class*=-ad]", "[id*=-ad]",
    "[class*=ad_]", "[id*=ad_]",
    "[class*=_ad]", "[id*=_ad]",
    "[class*=adsbygoogle]",
    # breadcrumbs / tag rows (usually nav widgets that survived <nav> strip)
    "[class*=breadcrumb]", "[id*=breadcrumb]",
    "[aria-label*=breadcrumb]", "[aria-label*=Breadcrumb]",
    "[class*=tag-list]", "[class*=tags-list]",
    "[class*=post-tags]",
    # popups / modals / dialogs
    "[class*=popup]", "[id*=popup]",
    "[class*=modal]", "[id*=modal]",
    "[role=dialog]", "[aria-modal=true]", "dialog",
    # newsletter / subscribe
    "[class*=newsletter]", "[id*=newsletter]",
    "[class*=subscribe]", "[id*=subscribe]",
    # social / share widgets
    "[class*=share-]", "[class*=social-]",
    "[class*=share-buttons]", "[class*=social-share]",
    # related / recommended
    "[class*=related]", "[id*=related]",
    "[class*=recommended]", "[id*=recommended]",
    "[class*=read-more]",
    # comments
    "[class*=comments]", "[id*=comments]",
    "#disqus_thread", "[id*=disqus]",
    # hidden / SEO-stuffing
    "[hidden]", "[aria-hidden=true]"
  ]

  # Strip all KB-junk selectors, then walk inline `style` attributes
  # for display:none / visibility:hidden (Floki has no attribute-value-
  # contains selector that handles arbitrary CSS, so we filter manually).
  defp strip_kb_junk(doc) do
    doc =
      Enum.reduce(@kb_junk_selectors, doc, fn selector, acc ->
        try do
          Floki.filter_out(acc, selector)
        rescue
          _ -> acc
        end
      end)

    Floki.traverse_and_update(doc, fn
      {_tag, attrs, _children} = node ->
        style = Enum.find_value(attrs, fn
          {"style", v} -> v
          _ -> nil
        end)

        if is_binary(style) and hidden_style?(style),
          do: nil,
          else: node

      other -> other
    end)
  end

  defp hidden_style?(s) do
    lower = String.downcase(s)
    String.contains?(lower, "display:none") or
      String.contains?(lower, "display: none") or
      String.contains?(lower, "visibility:hidden") or
      String.contains?(lower, "visibility: hidden")
  end

  # After extraction, drop lines that are mostly link text. Catches
  # "you may also like" lists, breadcrumb trails, footer link rows
  # that survived earlier strips. Threshold: a line is dropped if
  # ≥80% of its non-whitespace chars came from link text.
  #
  # We can't see link-vs-non-link split at the text level, so use a
  # simpler proxy: drop lines that are short (<60 chars), have no
  # period, and consist of multiple capitalised tokens separated by
  # `|`, `·`, `>`, `→`, or pipe-style separators (typical link rows).
  defp drop_link_heavy_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&link_heavy_line?/1)
    |> Enum.join("\n")
    |> collapse_ws()
  end

  defp link_heavy_line?(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> false
      String.length(trimmed) >= 60 -> false
      String.contains?(trimmed, ".") -> false
      Regex.match?(~r/[|·›>→»]/u, trimmed) -> true
      true -> false
    end
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
