# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.WebCrawl do
  @moduledoc """
  Bounded, ephemeral, same-domain BFS crawl. Reads a small sub-site
  off one start URL and returns the full corpus inline in the tool
  result so the model can reason across many pages in one turn.

  Distinguishing line vs. siblings:

    * `web_fetch`   — ONE page.
    * `fetch_index` — KB lookup over already-indexed content.
    * `/index`      — admin slash-command crawl that PERSISTS into the
                      KB; outlives the turn.
    * `web_crawl`   — this tool. Ephemeral. Result lives for this
                      turn only.

  Caps (from `AgentSettings`):

    * `max_pages`            — default 20, hard cap 50.
    * `max_depth`            — default 2 (start URL = 0), hard cap 4.
    * `max_chars_per_page`   — default 3000; per-page truncation.
    * `per_fetch_delay_ms`   — default 300 ms; politeness gap.
    * `total_timeout_ms`     — default 30 s; tool returns whatever's
                                fetched at the deadline.

  Same-domain filter is on the registrable domain (eTLD+1); follows
  links across subdomains of the same registrable domain when
  `same_domain_only: true` (default).

  Skip lists mirror the `/index` pipeline:

    * Known-binary / known-asset extensions (PDF, ZIP, images, fonts, …).
    * Asset / build-artifact path segments (`node_modules`, `dist`, …).

  Returned shape:

      %{
        pages: [
          %{url, title, text, depth, fetched_ms},
          ...
        ],
        skipped: [%{url, reason}, ...],
        summary: %{
          start_url, fetched_count, skipped_count,
          total_chars, truncated_pages, elapsed_ms, deadline_hit
        }
      }

  The model reads `pages[*].text` for content + `pages[*].url` to
  attribute its answer. `skipped[*].reason` surfaces 4xx / 5xx /
  binary / asset filter explanations so the model can decide whether
  to suggest a different start URL.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Web.Fetcher
  require Logger

  # Mirror the `/index` pipeline's skip lists so we treat the same
  # binary/asset URLs as non-crawl. Kept in-module to avoid the
  # cross-module coupling that would force the Commands pipeline to
  # care about a tool.
  @skip_extensions ~w(
    .pdf .doc .docx .xls .xlsx .ppt .pptx .rtf .odt
    .zip .tar .gz .tgz .bz2 .7z .rar
    .png .jpg .jpeg .gif .webp .svg .ico .bmp .tiff .heic
    .mp3 .mp4 .webm .mov .avi .mkv .wav .ogg .flac
    .css .js .mjs .map .woff .woff2 .ttf .otf .eot
    .exe .dmg .iso .deb .rpm .apk
  )

  @asset_path_segments ~w(
    _images _static _assets _site _book
    node_modules bower_components
    dist build target
    .next .nuxt .svelte-kit .docusaurus .vuepress
    .cache .parcel-cache .turbo .angular .gradle .dart_tool
    __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox
    htmlcov .nyc_output
    vendor
    .idea .vscode
    .git .svn .hg
    .terraform cdk.out .serverless
  )

  @impl true
  def name, do: "web_crawl"

  @impl true
  def description do
    "BFS-crawl a sub-site starting at `start_url` and return all " <>
      "fetched pages inline. Use when a single `web_fetch` won't " <>
      "answer the question (e.g., 'go look at this site's whole " <>
      "courses section and pick…'). Same-domain only by default; " <>
      "ephemeral — nothing persisted to the KB."
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          start_url: %{
            type: "string",
            description: "The URL to begin the crawl from. Must be http(s)."
          },
          max_pages: %{
            type: "integer",
            description: "Maximum pages fetched (default #{AgentSettings.web_crawl_max_pages_default()}, hard cap #{AgentSettings.web_crawl_max_pages_hard_cap()})."
          },
          max_depth: %{
            type: "integer",
            description: "Maximum BFS depth — start URL is depth 0 (default #{AgentSettings.web_crawl_max_depth_default()}, hard cap #{AgentSettings.web_crawl_max_depth_hard_cap()})."
          },
          same_domain_only: %{
            type: "boolean",
            description: "When true (default), follow only links on the same registrable domain (eTLD+1) as start_url. When false, follow any http(s) link — DON'T set false unless you really mean it."
          }
        },
        required: ["start_url"]
      }
    }
  end

  @impl true
  def execute(args, _ctx) do
    start_url = Map.get(args, "start_url")

    cond do
      not is_binary(start_url) or start_url == "" ->
        {:error, "web_crawl: `start_url` required (string)"}

      not http_url?(start_url) ->
        {:error, "web_crawl: `start_url` must be http(s); got #{inspect(start_url)}"}

      true ->
        max_pages = clamp(
          Map.get(args, "max_pages", AgentSettings.web_crawl_max_pages_default()),
          1,
          AgentSettings.web_crawl_max_pages_hard_cap()
        )

        max_depth = clamp(
          Map.get(args, "max_depth", AgentSettings.web_crawl_max_depth_default()),
          0,
          AgentSettings.web_crawl_max_depth_hard_cap()
        )

        same_domain? = Map.get(args, "same_domain_only", true)

        opts = %{
          max_pages:           max_pages,
          max_depth:           max_depth,
          same_domain_only:    same_domain?,
          max_chars_per_page:  AgentSettings.web_crawl_max_chars_per_page(),
          per_fetch_delay_ms:  AgentSettings.web_crawl_per_fetch_delay_ms(),
          deadline_at:         System.monotonic_time(:millisecond) + AgentSettings.web_crawl_total_timeout_ms()
        }

        run_crawl(start_url, opts)
    end
  end

  # ── BFS loop ──────────────────────────────────────────────────────────

  defp run_crawl(start_url, opts) do
    started_at = System.monotonic_time(:millisecond)
    {:ok, root_host} = registrable_domain(start_url)
    canonical_start = canonicalize(start_url)

    state = %{
      queue:           :queue.from_list([{canonical_start, 0}]),
      seen:            MapSet.new([canonical_start]),
      pages:           [],
      skipped:         [],
      truncated_count: 0,
      root_host:       root_host,
      deadline_hit:    false
    }

    final = loop(state, opts)
    elapsed = System.monotonic_time(:millisecond) - started_at

    {:ok, %{
      "pages"   => Enum.reverse(final.pages),
      "skipped" => Enum.reverse(final.skipped),
      "summary" => %{
        "start_url"        => start_url,
        "fetched_count"    => length(final.pages),
        "skipped_count"    => length(final.skipped),
        "total_chars"      => Enum.reduce(final.pages, 0, fn p, n -> n + String.length(p["text"] || "") end),
        "truncated_pages"  => final.truncated_count,
        "elapsed_ms"       => elapsed,
        "deadline_hit"     => final.deadline_hit
      }
    }}
  end

  defp loop(state, opts) do
    cond do
      length(state.pages) >= opts.max_pages ->
        state

      System.monotonic_time(:millisecond) >= opts.deadline_at ->
        %{state | deadline_hit: true}

      :queue.is_empty(state.queue) ->
        state

      true ->
        {{:value, {url, depth}}, q2} = :queue.out(state.queue)
        state = %{state | queue: q2}

        case fetch_and_collect(url, depth, state, opts) do
          {:ok, page, links} ->
            new_pages = [page | state.pages]
            new_truncated = state.truncated_count + (if page["_truncated"], do: 1, else: 0)

            state =
              %{state |
                pages:           new_pages,
                truncated_count: new_truncated,
                queue:           enqueue_links(state, links, depth + 1, opts),
                seen:            Enum.reduce(links, state.seen, &MapSet.put(&2, &1))
              }

            if opts.per_fetch_delay_ms > 0 do
              :timer.sleep(opts.per_fetch_delay_ms)
            end

            loop(state, opts)

          {:skip, reason} ->
            state = %{state | skipped: [%{"url" => url, "reason" => reason} | state.skipped]}
            loop(state, opts)
        end
    end
  end

  defp enqueue_links(state, _links, next_depth, opts) when next_depth > opts.max_depth, do: state.queue
  defp enqueue_links(state, links, next_depth, opts) do
    Enum.reduce(links, state.queue, fn link, q ->
      cond do
        MapSet.member?(state.seen, link) ->
          q

        opts.same_domain_only and not same_domain?(state.root_host, link) ->
          q

        true ->
          :queue.in({link, next_depth}, q)
      end
    end)
  end

  # ── per-page fetch ────────────────────────────────────────────────────

  defp fetch_and_collect(url, depth, _state, opts) do
    cond do
      skip_extension?(url) ->
        {:skip, "binary_or_asset_extension"}

      skip_asset_path?(url) ->
        {:skip, "asset_or_build_path_segment"}

      true ->
        case Fetcher.fetch(url, max_chars: opts.max_chars_per_page * 2, include_html: true) do
          {:ok, %{content: text} = result} when is_binary(text) and text != "" ->
            {trimmed, truncated?} = truncate(text, opts.max_chars_per_page)
            title = Map.get(result, :title) || ""
            html  = Map.get(result, :html) || ""

            final_url = Map.get(result, :final_url) || url

            page = %{
              "url"        => final_url,
              "title"      => title,
              "text"       => trimmed,
              "depth"      => depth,
              "_truncated" => truncated?
            }

            links = extract_links_from_html(html, final_url)
            {:ok, page, links}

          {:ok, %{} = _result} ->
            {:skip, "no_text_extracted"}

          {:error, reason} ->
            {:skip, format_error(reason)}
        end
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp http_url?(s) when is_binary(s) do
    case URI.parse(s) do
      %URI{scheme: "http"}  -> true
      %URI{scheme: "https"} -> true
      _                     -> false
    end
  end

  defp canonicalize(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{fragment: f} = u when not is_nil(f) ->
        %{u | fragment: nil} |> URI.to_string()

      _ ->
        url
    end
  end

  defp registrable_domain(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        # Simple eTLD+1: take last two labels. Misses platform-specific
        # multi-label TLDs (.co.uk, .com.au) — treats them as separate
        # second-level domains, which over-restricts crawling there. Good
        # enough for v1; revisit if it bites in practice.
        labels = String.split(host, ".")
        case Enum.take(labels, -2) do
          [a, b] -> {:ok, a <> "." <> b}
          _      -> {:ok, host}
        end

      _ ->
        {:ok, ""}
    end
  end

  defp same_domain?(root_host, url) do
    case registrable_domain(url) do
      {:ok, ^root_host} -> true
      _                 -> false
    end
  end

  defp skip_extension?(url) do
    path = URI.parse(url).path || ""
    ext = path |> String.downcase() |> Path.extname()
    ext != "" and ext in @skip_extensions
  end

  defp skip_asset_path?(url) do
    path = URI.parse(url).path || ""
    segs = String.split(path, "/", trim: true)
    Enum.any?(segs, fn s -> s in @asset_path_segments end)
  end

  defp truncate(text, max) when byte_size(text) > max do
    {String.slice(text, 0, max) <> "\n\n[…truncated…]", true}
  end
  defp truncate(text, _max), do: {text, false}

  # Parse HTML with Floki, extract `<a href>`, honour `<base href>` per
  # HTML §4.2.3, resolve relatives against the page URL, deduplicate.
  defp extract_links_from_html(html, page_url) when is_binary(html) and html != "" do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        base = effective_base_url(doc, page_url)

        Floki.attribute(doc, "a", "href")
        |> Enum.map(&resolve_url(&1, base))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&http_url?/1)
        |> Enum.map(&canonicalize/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end
  defp extract_links_from_html(_, _), do: []

  defp effective_base_url(doc, page_url) do
    case Floki.attribute(doc, "base", "href") do
      [href | _] when is_binary(href) and href != "" ->
        try do
          page_url |> URI.merge(href) |> URI.to_string()
        rescue
          _ -> page_url
        end

      _ ->
        page_url
    end
  end

  defp resolve_url(href, base_url) when is_binary(href) and href != "" do
    try do
      case URI.parse(href) do
        %URI{scheme: nil} = rel -> base_url |> URI.merge(rel) |> URI.to_string()
        _                       -> href
      end
    rescue
      _ -> nil
    end
  end
  defp resolve_url(_, _), do: nil

  defp clamp(v, lo, hi) when is_integer(v), do: max(lo, min(v, hi))
  defp clamp(_, lo, _),                     do: lo

  defp format_error({:fetch_failed, reason, _url, _tried}), do: "fetch_failed: #{inspect(reason) |> String.slice(0, 200)}"
  defp format_error({:invalid_url, _}),                     do: "invalid_url"
  defp format_error(other),                                 do: "fetch_error: #{inspect(other) |> String.slice(0, 200)}"
end
