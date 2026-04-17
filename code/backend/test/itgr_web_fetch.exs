# Tests for the CMP-aware web-fetch subsystem:
#   - Pure-function tests for Util.Url, Web.CmpDetector, Web.Fallback,
#     Web.ReaderExtractor.
#   - Orchestrator tests for Web.Fetcher with an injected http_fn mock,
#     covering the clean-fetch, CMP-then-AMP, CMP-then-archive, and
#     hard-failure paths.
#   - A `@tag :network` block at the end hits real GDPR-walled sites.
#     Run those explicitly: `mix test test/itgr_web_fetch.exs --only network`.

defmodule Itgr.WebFetch do
  use ExUnit.Case, async: true

  alias Dmhai.Util.Url
  alias Dmhai.Web.{CmpDetector, ConsentSeeder, Fallback, Fetcher, ReaderExtractor}

  # ─── Util.Url ────────────────────────────────────────────────────────────

  describe "Url helpers" do
    test "parse rejects bad schemes" do
      assert Url.parse("ftp://example.com") == nil
      assert Url.parse("not a url") == nil
    end

    test "normalise lowercases host, drops trailing slash, strips fragment" do
      assert Url.normalise("HTTPS://Example.com/Foo/#bar") == "https://example.com/Foo"
    end

    test "with_host preserves path+query" do
      assert Url.with_host("https://example.com/article?id=1", "amp.example.com") ==
               "https://amp.example.com/article?id=1"
    end

    test "prepend_path / append_path" do
      assert Url.prepend_path("https://x.com/article", "amp") == "https://x.com/amp/article"
      assert Url.append_path("https://x.com/article", "amp")  == "https://x.com/article/amp"
    end

    test "with_query merges and overwrites" do
      out = Url.with_query("https://x.com/foo?a=1", %{b: 2, a: 9})
      assert String.contains?(out, "a=9")
      assert String.contains?(out, "b=2")
    end

    test "bare_host strips www" do
      assert Url.bare_host("https://www.example.com/x") == "example.com"
    end
  end

  # ─── CmpDetector ─────────────────────────────────────────────────────────

  describe "CmpDetector" do
    test "detects OneTrust" do
      body = """
      <html><head>
        <script src="https://cdn.cookielaw.org/scripttemplates/otSDKStub.js"></script>
      </head></html>
      """
      assert {:cmp, :onetrust} = CmpDetector.detect(body)
    end

    test "detects Sourcepoint" do
      body = ~s(<script>window._sp_v1_queue_ = [];</script>)
      assert {:cmp, :sourcepoint} = CmpDetector.detect(body)
    end

    test "detects Quantcast Choice" do
      body = ~s(<script src="https://quantcast.mgr.consensu.org/cmp.js"></script>)
      assert {:cmp, :quantcast} = CmpDetector.detect(body)
    end

    test "detects Cookiebot" do
      body = ~s(<script id="Cookiebot" src="https://consent.cookiebot.com/uc.js"></script>)
      assert {:cmp, :cookiebot} = CmpDetector.detect(body)
    end

    test "detects Didomi" do
      body = ~s(<script>window.didomiConfig = {};</script>)
      assert {:cmp, :didomi} = CmpDetector.detect(body)
    end

    test "detects raw TCF v2" do
      body = """
      <script>
        window.__tcfapi = function(command, version, callback) { ... }
      </script>
      """
      assert {:cmp, :tcf_v2} = CmpDetector.detect(body)
    end

    test "detects generic cookie-wall class" do
      body = ~s(<div class="cookie-wall">please accept</div>)
      assert {:cmp, :generic_banner} = CmpDetector.detect(body)
    end

    test "detects OneTrust attribute form (data-onetrust-script-id)" do
      body = ~s(<script data-onetrust-script-id="abc-123"></script>)
      assert {:cmp, :onetrust} = CmpDetector.detect(body)
    end

    test "detects OneTrust ONETRUST_SCRIPT_ID config marker" do
      body = ~s(<script data-config='{"ONETRUST_SCRIPT_ID":"xyz"}'></script>)
      assert {:cmp, :onetrust} = CmpDetector.detect(body)
    end

    test "detects Datadome bot challenge (the 774-byte captcha shell)" do
      body =
        ~s(<html><head><title>reuters.com</title></head><body>) <>
        ~s(<p id="cmsg">Please enable JS and disable any ad blocker</p>) <>
        ~s(<script src="https://ct.captcha-delivery.com/i.js"></script>) <>
        ~s(</body></html>)
      assert {:cmp, :datadome} = CmpDetector.detect(body)
    end

    test "detects Cloudflare challenge interstitial" do
      body = ~s(<script src="/cdn-cgi/challenge-platform/h/g/orchestrate/..." ></script>)
      assert {:cmp, :cloudflare_challenge} = CmpDetector.detect(body)
    end

    test "detects Akamai Bot Manager cookie markers" do
      body = ~s(<script>document.cookie="_abck=ABC123;bm_sz=XYZ";</script>)
      assert {:cmp, :akamai_bot} = CmpDetector.detect(body)
    end

    test "bot_challenge?/1 flags the challenge vendors" do
      assert CmpDetector.bot_challenge?(:datadome)
      assert CmpDetector.bot_challenge?(:cloudflare_challenge)
      assert CmpDetector.bot_challenge?(:akamai_bot)
      refute CmpDetector.bot_challenge?(:onetrust)
      refute CmpDetector.bot_challenge?(:tcf_v2)
    end

    test "clean HTML is reported as :clean" do
      assert CmpDetector.detect("<html><body><article>hello</article></body></html>") == :clean
    end

    test "non-binary input is :clean" do
      assert CmpDetector.detect(nil) == :clean
    end
  end

  # ─── ConsentSeeder ───────────────────────────────────────────────────────

  describe "ConsentSeeder" do
    test "request_headers includes UA + Cookie + GPC" do
      hdrs = ConsentSeeder.request_headers("MyUA/1.0")
      names = Enum.map(hdrs, fn {k, _} -> k end)
      assert "user-agent" in names
      assert "cookie" in names
      assert "sec-gpc" in names
      assert {"user-agent", "MyUA/1.0"} in hdrs
    end

    test "cookie_header contains dismissed flags for common banners" do
      hdr = ConsentSeeder.cookie_header()
      assert hdr =~ "cookieconsent_status=dismiss"
      assert hdr =~ "gdpr_consent=yes"
      assert hdr =~ "OptanonAlertBoxClosed="
    end
  end

  # ─── Fallback ────────────────────────────────────────────────────────────

  describe "Fallback" do
    test "amp_variants returns deduped candidate URLs" do
      vs = Fallback.amp_variants("https://www.bbc.com/news/article-123.html")
      assert "https://www.bbc.com/amp/news/article-123.html" in vs
      assert "https://www.bbc.com/news/article-123.html/amp" in vs
      assert Enum.any?(vs, &String.contains?(&1, "amp.bbc.com"))
      assert Enum.any?(vs, &String.contains?(&1, "output=amp"))
      assert length(Enum.uniq(vs)) == length(vs)
    end

    test "archive_mirrors returns archive.ph and wayback" do
      mirrors = Fallback.archive_mirrors("https://example.com/x")
      assert Enum.any?(mirrors, &String.contains?(&1, "archive.ph"))
      assert Enum.any?(mirrors, &String.contains?(&1, "web.archive.org"))
    end

    test "all_variants concatenates amp then archives" do
      amp   = Fallback.amp_variants("https://example.com/x")
      mirr  = Fallback.archive_mirrors("https://example.com/x")
      all   = Fallback.all_variants("https://example.com/x")
      assert all == amp ++ mirr
    end
  end

  # ─── ReaderExtractor ─────────────────────────────────────────────────────

  describe "ReaderExtractor" do
    test "prefers semantic <article> over <div>" do
      html = """
      <html>
        <body>
          <div>some short chrome stuff</div>
          <article>
            <h1>The Headline</h1>
            <p>#{String.duplicate("This is the article body. ", 30)}</p>
            <p>#{String.duplicate("Another paragraph with substance. ", 30)}</p>
          </article>
          <footer>copyright</footer>
        </body>
      </html>
      """

      result = ReaderExtractor.extract(html, "https://example.com/a")
      assert result != nil
      assert String.contains?(result.text, "article body")
    end

    test "falls back to density scoring when no semantic tag exists" do
      long = String.duplicate("actual content words here. ", 40)
      html = """
      <html><body>
        <div class="sidebar">shorty</div>
        <div class="main-reader-container"><p>#{long}</p></div>
        <div class="also-short">nothing</div>
      </body></html>
      """

      result = ReaderExtractor.extract(html)
      assert result != nil
      assert String.contains?(result.text, "actual content words")
    end

    test "picks og:title when present" do
      html = """
      <html><head>
        <meta property="og:title" content="The Real Title">
        <title>Boring fallback</title>
      </head>
      <body><article><p>#{String.duplicate("text ", 100)}</p></article></body></html>
      """
      result = ReaderExtractor.extract(html)
      assert result.title == "The Real Title"
    end

    test "returns nil when content is below min threshold" do
      html = "<html><body><article>too short</article></body></html>"
      assert ReaderExtractor.extract(html) == nil
    end

    test "returns nil on unparseable input" do
      # Floki can parse almost anything, but a non-binary returns nil.
      # For binary, we build a degenerate doc with no content.
      assert ReaderExtractor.extract("") == nil
    end
  end

  # ─── Fetcher orchestrator (with injected http_fn mock) ───────────────────

  describe "Fetcher" do
    defp mock_response(status, body, final_url) do
      %{status: status, body: body, final_url: final_url}
    end

    defp long_body(content), do: String.duplicate("<p>" <> content <> "</p>", 50)

    test "clean response returns :direct source and extracted content" do
      body =
        "<html><body><article><h1>Hi</h1>" <>
        long_body("The quick brown fox jumps over the lazy dog. ") <>
        "</article></body></html>"

      http_fn = fn url, _hdrs -> {:ok, mock_response(200, body, url)} end
      assert {:ok, result} = Fetcher.fetch("https://example.com/x", http_fn: http_fn)
      assert result.source == :direct
      assert result.cmp == nil
      assert String.contains?(result.content, "quick brown fox")
    end

    test "CMP on primary → AMP variant with clean body wins" do
      cmp_body = ~s(<script src="https://cdn.cookielaw.org/otSDKStub.js"></script>)
      clean_body =
        "<html><body><article>" <>
        long_body("Clean article from the AMP URL with substantial text. ") <>
        "</article></body></html>"

      http_fn = fn url, _hdrs ->
        if String.contains?(url, "/amp/") or String.contains?(url, "amp.") or
             String.contains?(url, "output=amp") or String.contains?(url, ".amp") do
          {:ok, mock_response(200, clean_body, url)}
        else
          {:ok, mock_response(200, cmp_body, url)}
        end
      end

      assert {:ok, result} =
               Fetcher.fetch("https://www.example.com/news/story.html", http_fn: http_fn)

      assert result.cmp == :onetrust
      assert result.source in [:amp_or_mirror]
      assert String.contains?(result.content, "Clean article")
    end

    test "all AMP variants also walled → archive.today wins" do
      cmp_body = ~s(<script src="https://cdn.cookielaw.org/otSDKStub.js"></script>)
      clean =
        "<html><body><article>" <>
        long_body("From archive. ") <>
        "</article></body></html>"

      http_fn = fn url, _hdrs ->
        cond do
          String.contains?(url, "archive.ph") ->
            {:ok, mock_response(200, clean, url)}

          String.contains?(url, "web.archive.org") ->
            {:ok, mock_response(200, clean, url)}

          true ->
            {:ok, mock_response(200, cmp_body, url)}
        end
      end

      assert {:ok, result} =
               Fetcher.fetch("https://www.example.com/news/story.html", http_fn: http_fn)

      assert result.cmp == :onetrust
      assert result.source in [:archive_today, :wayback]
      assert String.contains?(result.content, "From archive")
    end

    test "CMP everywhere → {:error, {:cmp_wall, …}}" do
      cmp_body = ~s(<script src="https://cdn.cookielaw.org/otSDKStub.js"></script>)
      http_fn  = fn url, _hdrs -> {:ok, mock_response(200, cmp_body, url)} end

      assert {:error, {:cmp_wall, url, cmp: :onetrust, tried: tried}} =
               Fetcher.fetch("https://example.com/x", http_fn: http_fn)

      assert url == "https://example.com/x"
      assert length(tried) > 1
    end

    test "non-200 primary is :fetch_failed (no CMP bail-out)" do
      http_fn = fn _url, _hdrs -> {:ok, mock_response(500, "", nil)} end

      assert {:error, {:fetch_failed, {:http_status, 500}, "https://example.com/x", _}} =
               Fetcher.fetch("https://example.com/x", http_fn: http_fn)
    end

    test "invalid URL → {:error, {:invalid_url, ...}}" do
      assert {:error, {:invalid_url, "not a url"}} = Fetcher.fetch("not a url")
    end

    test "clean response is truncated when exceeding :max_chars" do
      body =
        "<html><body><article>" <>
        long_body("abcdefghij ") <>
        "</article></body></html>"

      http_fn = fn url, _hdrs -> {:ok, mock_response(200, body, url)} end
      assert {:ok, r} =
               Fetcher.fetch("https://example.com/x", http_fn: http_fn, max_chars: 100)

      assert r.truncated == true
      assert String.length(r.content) <= 100
    end
  end

  # ─── Real-site integration (network, opt-in) ─────────────────────────────
  #
  # Run explicitly:
  #   mix test test/itgr_web_fetch.exs --only network
  #
  # These tests DO make outbound HTTP. They verify that the fetcher returns
  # a STRUCTURED response in all cases. A hard `{:cmp_wall, …}` is NOT a
  # test failure — it is a real-world limit some sites impose that only a
  # headless browser can bypass. We log the outcome so CI/dev can see hit
  # rates. What we fail on: crashes, bad response shapes, or unexpected
  # error shapes.

  describe "real sites (network)" do
    # Markers that should NOT appear in the returned content — if they do,
    # we got chrome/captcha/consent shell instead of an article.
    @bad_content_markers [
      ~r/please\s+enable\s+JS/i,
      ~r/enable\s+JavaScript\s+(and|to)/i,
      ~r/Just\s+a\s+moment\.\.\./i,
      ~r/Checking if the site connection is secure/i,
      ~r/verifying you are human/i,
      ~r/cookie\s+(policy|preferences)/i,
      ~r/accept\s+(all\s+)?cookies/i
    ]

    defp assert_structured(site, result) do
      case result do
        {:ok, r} ->
          assert is_binary(r.content)
          assert String.length(r.content) > 500,
                 "#{site}: content too short (#{String.length(r.content)} chars) — " <>
                 "likely got chrome/captcha instead of article"

          bad = Enum.filter(@bad_content_markers, &Regex.match?(&1, r.content))
          if bad != [] and String.length(r.content) < 3_000 do
            flunk(
              "#{site}: short response (#{String.length(r.content)} chars) contains " <>
              "bad-content markers #{inspect(bad)} — likely captcha/consent shell, not article"
            )
          end

          IO.puts("#{site}: OK source=#{r.source} cmp=#{inspect(r.cmp)} " <>
                  "len=#{String.length(r.content)} tried=#{length(r.tried)}")
          :ok

        {:error, {:cmp_wall, _, cmp: vendor, tried: tried}} ->
          IO.puts("#{site}: CMP-WALL cmp=#{vendor} tried=#{length(tried)} " <>
                  "(unbypassable without headless browser — expected for some sites)")
          :cmp_wall

        {:error, {:fetch_failed, reason, _, tried}} ->
          IO.puts("#{site}: FETCH-FAILED reason=#{inspect(reason)} tried=#{length(tried)}")
          :fetch_failed

        other ->
          flunk("#{site}: unexpected result shape #{inspect(other)}")
      end
    end

    @tag :network
    @tag timeout: 90_000
    test "BBC News (OneTrust-walled in EU)" do
      assert_structured("bbc.com",
        Fetcher.fetch("https://www.bbc.com/news", timeout_ms: 20_000))
    end

    @tag :network
    @tag timeout: 90_000
    test "Le Monde (aggressive French TCF v2 wall)" do
      # Known to be one of the hardest CMPs — documents the tool's limit.
      assert_structured("lemonde.fr",
        Fetcher.fetch("https://www.lemonde.fr/", timeout_ms: 20_000))
    end

    @tag :network
    @tag timeout: 90_000
    test "NYTimes front page" do
      assert_structured("nytimes.com",
        Fetcher.fetch("https://www.nytimes.com/", timeout_ms: 20_000))
    end

    @tag :network
    @tag timeout: 90_000
    test "Reuters (OneTrust)" do
      assert_structured("reuters.com",
        Fetcher.fetch("https://www.reuters.com/world/", timeout_ms: 20_000))
    end

    @tag :network
    @tag timeout: 90_000
    test "The Guardian (Sourcepoint in EU)" do
      assert_structured("theguardian.com",
        Fetcher.fetch("https://www.theguardian.com/international", timeout_ms: 20_000))
    end

    @tag :network
    @tag timeout: 90_000
    test "Wikipedia (no CMP) — clean-path sanity check" do
      url = "https://en.wikipedia.org/wiki/Elixir_(programming_language)"
      assert {:ok, r} = Fetcher.fetch(url, timeout_ms: 20_000)
      assert r.source == :direct
      assert r.cmp == nil
      assert String.contains?(r.content, "Elixir")
      IO.puts("wikipedia: OK len=#{String.length(r.content)}")
    end
  end
end
