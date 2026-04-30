# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Commands.Pipelines.URL do
  @moduledoc """
  URL `/wiki` pipeline. Sequential BFS crawl over same-prefix pages,
  bounded by `learn_url_max_depth` and `learn_url_max_pages`
  (AgentSettings). Each page's fetch+ingest emits a
  `session_progress` 'tool' row labeled `IndexWiki -> <sliced url>`,
  pending while the page is being processed and flipped to done
  with a `duration_ms` once the row's work finishes.

  The progress rows accumulate during the crawl; the FE renders
  them flat under the accepted_ack while the crawl is in flight,
  then nests them under the final command_ack once the run
  completes (per `buildSessionTimeline` in manager-chat.js).

  See specs/commands.md §URL.
  """

  alias Dmhai.VectorDB
  alias Dmhai.Web.Fetcher
  alias Dmhai.Agent.{AgentSettings, BackgroundPipelines, Oracle, SessionProgress, UserAgentMessages}
  alias Dmhai.Commands.WikiAck
  require Logger

  @max_chars_per_page 200_000
  @sliced_url_max_len 60

  # Path-extension allowlist would be impractical (millions of valid
  # text mime types come without obvious extensions). We use a
  # blocklist of known-binary / known-asset extensions instead —
  # cheaper to maintain and avoids the worst false-failures: doc
  # sites linking to PDF reference cards, ZIP downloads, font
  # files, etc. Each skip saves a fetch we'd otherwise count as
  # "failed to extract".
  @skip_extensions ~w(
    .pdf .doc .docx .xls .xlsx .ppt .pptx .rtf .odt
    .zip .tar .gz .tgz .bz2 .7z .rar
    .png .jpg .jpeg .gif .webp .svg .ico .bmp .tiff .heic
    .mp3 .mp4 .webm .mov .avi .mkv .wav .ogg .flac
    .css .js .mjs .map .woff .woff2 .ttf .otf .eot
    .exe .dmg .iso .deb .rpm .apk
  )

  @doc "Heuristic — is this an http(s) URL?"
  @spec url?(String.t()) :: boolean()
  def url?(s) when is_binary(s) do
    String.starts_with?(s, "http://") or String.starts_with?(s, "https://")
  end

  def url?(_), do: false

  @doc """
  Returns the SYNC accepted-ack immediately; the actual crawl runs
  in a background Task. The Task emits one `session_progress` 'tool'
  row per page (so the FE shows the crawl unfolding in real time),
  then posts a final `command_ack` summarising what was indexed.
  """
  @spec run_async(String.t(), String.t(), String.t()) :: {:ok, String.t()}
  def run_async(url, session_id, user_id) when is_binary(url) do
    Task.Supervisor.start_child(Dmhai.Agent.TaskSupervisor, fn ->
      do_crawl(url, session_id, user_id)
    end)

    # URL itself carries no language signal — Oracle defaults to
    # English here, which is the right behaviour for path-shaped args.
    {:ok, Oracle.localize(WikiAck.accepted_ack(url), url)}
  end

  # Top-level crawl: derive same-prefix scope, BFS until the queue
  # empties or the page cap is hit, then post the summary ack.
  # Registers with `BackgroundPipelines` for the duration so the
  # `/poll` orphan-cleanup sweeper doesn't flip our in-flight
  # pending rows to `[orphan-cleanup]` while ingest is running.
  defp do_crawl(start_url, session_id, user_id) do
    BackgroundPipelines.register(session_id)

    try do
      prefix    = same_prefix(start_url)
      max_depth = AgentSettings.learn_url_max_depth()
      max_pages = AgentSettings.learn_url_max_pages()

      state = %{
        session_id: session_id,
        user_id:    user_id,
        prefix:     prefix,
        max_depth:  max_depth,
        max_pages:  max_pages,
        seen:       MapSet.new([start_url]),  # both visited AND queued — single dedupe set
        queue:      :queue.from_list([{start_url, 0}]),
        indexed:    0,
        errors:     0,
        first_lang_signal: nil   # first non-empty page text drives the summary's localisation
      }

      final_state = bfs(state)

      summary = compose_summary(final_state, prefix)
      lang_signal = final_state.first_lang_signal || start_url
      post_ack(session_id, user_id, Oracle.localize(summary, lang_signal))
    rescue
      e ->
        Logger.error("[Commands.URL] crawl crashed on #{start_url}: #{Exception.message(e)}")
        post_ack(session_id, user_id,
          Oracle.localize("Crawl crashed for `#{start_url}`: #{Exception.message(e)}", start_url))
    after
      BackgroundPipelines.unregister(session_id)
    end
  end

  defp bfs(state) do
    cond do
      state.indexed >= state.max_pages ->
        state

      true ->
        case :queue.out(state.queue) do
          {:empty, _} ->
            state

          {{:value, {url, depth}}, rest_q} ->
            state2 = %{state | queue: rest_q}

            if depth > state.max_depth do
              bfs(state2)
            else
              bfs(process_page(state2, url, depth))
            end
        end
    end
  end

  # Fetch + ingest one page; emit the matching tool progress row and
  # push outbound same-prefix links onto the queue.
  defp process_page(state, url, depth) do
    ctx   = %{session_id: state.session_id, user_id: state.user_id, task_id: nil}
    label = "IndexWiki -> #{slice_url(url)}"

    {:ok, prog_row} = SessionProgress.append_tool_pending(ctx, label)
    started_ms      = System.monotonic_time(:millisecond)

    result = Fetcher.fetch(url, extractor: :kb, max_chars: @max_chars_per_page, include_html: true)

    case result do
      {:ok, %{title: title, content: text, html: html} = res} when is_binary(text) and text != "" ->
        # Redirect-out-of-prefix guard: a queued in-prefix URL may
        # 30x to an out-of-prefix (or off-host) URL. Fetcher follows
        # the redirect and returns the FINAL URL via :final_url.
        # Index only when the final landing is still inside scope —
        # otherwise we'd silently leak content from an unrelated
        # section / domain into the wiki under the original URL.
        final_url = Map.get(res, :final_url, url)

        if String.starts_with?(final_url, state.prefix) do
          effective_title = title || url

          attrs = %{
            scope:       :knowledge,
            user_id:     nil,
            source_kind: "url",
            source_ref:  url,
            title:       effective_title
          }

          ingest_status =
            case VectorDB.ingest(attrs, text) do
              {:ok, _info}   -> :ok
              {:error, _r}   -> :error
            end

          # Mark done AFTER ingest so duration_ms reflects fetch +
          # ingest end-to-end (the embedder is the bulk of per-page
          # wall-clock, not the HTTP fetch).
          duration_ms = System.monotonic_time(:millisecond) - started_ms
          SessionProgress.mark_tool_done(prog_row.id, duration_ms)

          new_seen_queue =
            if depth + 1 <= state.max_depth and (state.indexed + 1) < state.max_pages do
              queue_links(html, final_url, state.prefix, state.seen, state.queue, depth + 1)
            else
              {state.seen, state.queue}
            end

          {seen2, queue2} = new_seen_queue

          case ingest_status do
            :ok ->
              %{state |
                seen:    seen2,
                queue:   queue2,
                indexed: state.indexed + 1,
                first_lang_signal: state.first_lang_signal || text
              }

            :error ->
              %{state | seen: seen2, queue: queue2, errors: state.errors + 1}
          end
        else
          # Followed a redirect outside the prefix. Don't index,
          # don't queue links from it, count as a (silent) skip.
          duration_ms = System.monotonic_time(:millisecond) - started_ms
          SessionProgress.mark_tool_done(prog_row.id, duration_ms)
          %{state | errors: state.errors + 1}
        end

      _ ->
        # No usable content (CMP wall, empty body, fetch error, etc.) — count as
        # error, mark the row done, move on.
        duration_ms = System.monotonic_time(:millisecond) - started_ms
        SessionProgress.mark_tool_done(prog_row.id, duration_ms)
        %{state | errors: state.errors + 1}
    end
  end

  # Pull `<a href>` from `html`, resolve against the document's
  # effective base URL (HTML `<base href>` if present, else the
  # page URL), drop fragments, keep only same-prefix hits, and add
  # anything new to the seen-set + queue. `seen` doubles as
  # visited-AND-queued so we never enqueue duplicates.
  defp queue_links(html, page_url, prefix, seen, queue, child_depth) do
    case Floki.parse_document(html || "") do
      {:ok, doc} ->
        effective_base = effective_base_url(doc, page_url)

        Floki.attribute(doc, "a", "href")
        |> Enum.map(&resolve_url(&1, effective_base))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.reject(&binary_asset?/1)
        |> Enum.reduce({seen, queue}, fn link, {s, q} ->
          if MapSet.member?(s, link) do
            {s, q}
          else
            {MapSet.put(s, link), :queue.in({link, child_depth}, q)}
          end
        end)

      _ ->
        {seen, queue}
    end
  end

  # HTML `<base href="...">` overrides the document's effective
  # base for resolving every relative URL on the page (HTML §4.2.3).
  # SPAs commonly use it to declare the SITE root, e.g.
  # `<base href="../../">` from a deep page resolves to the
  # site root — at which point a hyperlink `api-reference/foo.html`
  # is meant to be `<root>/api-reference/foo.html`, NOT
  # `<page-dir>/api-reference/foo.html`. Without this, BFS over
  # docs sites that use a root `<base>` produces 404s for every
  # relative outbound link.
  defp effective_base_url(doc, page_url) do
    case Floki.attribute(doc, "base", "href") do
      [href | _] when is_binary(href) and href != "" ->
        try do
          page_url
          |> URI.merge(href)
          |> URI.to_string()
        rescue
          _ -> page_url
        end

      _ ->
        page_url
    end
  end

  defp resolve_url(href, base_url) when is_binary(href) and href != "" do
    # Drop non-navigable schemes up-front — `URI.merge` would happily
    # produce them, but they'd never match the same-prefix filter and
    # parsing them is a wasted cycle. Defense-in-depth.
    cond do
      String.starts_with?(href, "#")           -> nil
      String.starts_with?(href, "javascript:") -> nil
      String.starts_with?(href, "mailto:")     -> nil
      String.starts_with?(href, "tel:")        -> nil
      String.starts_with?(href, "data:")       -> nil

      true ->
        try do
          base_url
          |> URI.merge(href)
          |> Map.put(:fragment, nil)
          |> URI.to_string()
        rescue
          _ -> nil
        end
    end
  end

  defp resolve_url(_, _), do: nil

  # Skip URLs whose path extension is in the asset/binary blocklist.
  # The file would land at the kb extractor as raw bytes and produce
  # zero text — counted as "failed to extract" and inflating the
  # crawl's failure tally for no useful reason.
  defp binary_asset?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) ->
        ext = path |> Path.extname() |> String.downcase()
        ext != "" and ext in @skip_extensions

      _ ->
        false
    end
  end

  defp binary_asset?(_), do: false

  # Same-prefix scope: keep up to the start URL's last "/" so its
  # siblings (the rest of the docs section) qualify but unrelated
  # paths on the same host don't.
  #
  # Heuristic for the last path segment:
  #   * contains "." → looks like a file (`index.html`, `foo.json`)
  #     → use the parent directory as prefix root.
  #   * no "." → looks like a directory shorthand (`/api/bizproc`)
  #     → treat the path itself as the directory; append `/`.
  # Without this, `/wiki https://example.com/api/bizproc` (no
  # trailing slash, no extension) would derive prefix `/api/`
  # and over-broadly crawl unrelated sections.
  defp same_prefix(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        path = uri.path || "/"
        base = same_prefix_path(path)

        port = if uri.port && uri.port != default_port(scheme), do: ":#{uri.port}", else: ""
        "#{scheme}://#{host}#{port}#{base}"

      _ ->
        url
    end
  end

  defp same_prefix_path("/"), do: "/"
  defp same_prefix_path(""),  do: "/"
  defp same_prefix_path(path) do
    last = path |> String.split("/") |> List.last() |> Kernel.||("")

    cond do
      String.contains?(last, ".") ->
        # File-shaped → parent dir + "/"
        case Path.dirname(path) do
          "/" -> "/"
          d   -> d <> "/"
        end

      String.ends_with?(path, "/") ->
        path

      true ->
        # Directory-shaped, no trailing slash → append one.
        path <> "/"
    end
  end

  defp default_port("https"), do: 443
  defp default_port("http"),  do: 80
  defp default_port(_),       do: nil

  defp slice_url(url) do
    stripped =
      url
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("http://", "")

    if String.length(stripped) > @sliced_url_max_len do
      String.slice(stripped, 0, @sliced_url_max_len - 1) <> "…"
    else
      stripped
    end
  end

  defp compose_summary(state, prefix) do
    pages_word = if state.indexed == 1, do: "page", else: "pages"
    base = "I indexed #{state.indexed} #{pages_word} from `#{prefix}`."

    cond do
      state.indexed >= state.max_pages ->
        base <> " Stopped at the page cap (#{state.max_pages}); raise `learn_url_max_pages` to crawl deeper."

      state.errors > 0 ->
        base <> " (#{state.errors} pages failed to fetch or extract.)"

      true ->
        base
    end
  end

  defp post_ack(session_id, user_id, text) do
    UserAgentMessages.append(session_id, user_id, %{
      role:    "assistant",
      content: text,
      kind:    "command_ack"
    })
  end
end
