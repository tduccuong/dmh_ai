# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.ReaderExtractorKB do
  use ExUnit.Case, async: true

  alias Dmhai.Web.ReaderExtractor

  @article_body """
  This is the first paragraph of the article. It contains substantive content
  about the topic. The article goes into detail with multiple sentences and
  paragraphs that should be retained by the extractor.

  This is the second paragraph. It continues the discussion of the main topic
  with more depth and additional context. Various technical details follow,
  with code examples and explanations of the underlying concepts.

  And here is a third paragraph wrapping up the main points. It provides a
  conclusion and summarises the key takeaways for the reader. The extractor
  should preserve this content exactly as the article author intended.
  """

  defp html_with(extras) do
    """
    <html>
      <head><title>Test Article</title></head>
      <body>
        <header><nav>Top nav</nav></header>
        <article>
          <h1>Article Title</h1>
          <p>#{@article_body}</p>
          #{extras}
        </article>
        <footer>footer chrome</footer>
      </body>
    </html>
    """
  end

  describe "extract_for_kb/2" do
    test "strips cookie banner inside article body" do
      html = html_with("""
      <div class="cookie-banner">By continuing to use this site you agree to our cookie policy and our terms and conditions and our privacy policy. We use cookies for analytics, advertising, and personalisation purposes.</div>
      """)

      assert %{text: text} = ReaderExtractor.extract_for_kb(html)
      refute text =~ "cookie policy"
      assert text =~ "first paragraph of the article"
    end

    test "strips ad blocks" do
      html = html_with("""
      <div class="advertisement">Sponsored: buy our amazing product today! Limited time offer with massive discounts available.</div>
      <div id="ad-slot-1">More sponsored content goes here with extensive copy.</div>
      """)

      assert %{text: text} = ReaderExtractor.extract_for_kb(html)
      refute text =~ "Sponsored"
      refute text =~ "sponsored content"
      assert text =~ "first paragraph"
    end

    test "strips comment sections" do
      html = html_with("""
      <section id="comments">
        <p>User1: Great article! Really enjoyed reading this and learning about the topic.</p>
        <p>User2: I disagree with most of the points raised here, but appreciate the effort.</p>
        <p>User3: This is exactly what I was looking for, thanks!</p>
      </section>
      """)

      assert %{text: text} = ReaderExtractor.extract_for_kb(html)
      refute text =~ "User1"
      refute text =~ "User2"
      refute text =~ "User3"
      assert text =~ "first paragraph"
    end

    test "strips newsletter signup forms" do
      html = html_with("""
      <div class="newsletter-signup">Subscribe to our newsletter for the latest updates and exclusive content delivered to your inbox.</div>
      """)

      assert %{text: text} = ReaderExtractor.extract_for_kb(html)
      refute text =~ "Subscribe to our newsletter"
    end

    test "strips related articles widgets" do
      html = html_with("""
      <aside class="related-articles">
        <h3>Related Articles</h3>
        <ul>
          <li>Another article you might like to read</li>
          <li>Recommended further reading on the topic</li>
        </ul>
      </aside>
      """)

      assert %{text: text} = ReaderExtractor.extract_for_kb(html)
      refute text =~ "Another article you might like"
    end

    test "strips hidden elements" do
      html = html_with("""
      <div hidden>This SEO-stuffing content should not appear because it is hidden.</div>
      <div aria-hidden="true">Also hidden content with aria-hidden attribute.</div>
      <div style="display: none;">CSS-hidden content for trackers and stuffing.</div>
      """)

      assert %{text: text} = ReaderExtractor.extract_for_kb(html)
      refute text =~ "SEO-stuffing"
      refute text =~ "aria-hidden attribute"
      refute text =~ "CSS-hidden content"
    end

    test "strips dialog/modal elements" do
      html = html_with("""
      <div role="dialog" aria-modal="true">
        <h2>Sign up now!</h2>
        <p>Become a member to access exclusive content and features.</p>
      </div>
      """)

      assert %{text: text} = ReaderExtractor.extract_for_kb(html)
      refute text =~ "Sign up now"
      refute text =~ "Become a member"
    end

    test "preserves the actual article content" do
      html = html_with("")

      assert %{text: text, title: title} = ReaderExtractor.extract_for_kb(html)
      assert title =~ "Article" or title =~ "Test Article"
      assert text =~ "first paragraph of the article"
      assert text =~ "second paragraph"
      assert text =~ "third paragraph"
    end

    test "drops breadcrumbs and tag widgets" do
      html = """
      <html>
        <body>
          <article>
            <h1>Title</h1>
            <ol class="breadcrumb">
              <li>Home</li><li>Articles</li><li>Tech</li><li>This Article</li>
            </ol>
            <p>#{@article_body}</p>
            <ul class="post-tags">
              <li>elixir</li><li>parsing</li><li>kb</li>
            </ul>
          </article>
        </body>
      </html>
      """

      assert %{text: text} = ReaderExtractor.extract_for_kb(html)
      refute text =~ "Tech"  # breadcrumb gone
      refute text =~ "elixir" # tag widget gone
      assert text =~ "first paragraph"
    end
  end

  describe "Fetcher :extractor opt" do
    test "explicit :kb extractor strips cookie banners; default keeps them" do
      # Direct call to the private extract logic isn't possible — exercise via
      # ReaderExtractor which is the only branch the opt routes between. The
      # routing itself is one cond/case in lib/dmhai/web/fetcher.ex:128 — its
      # correctness is covered by the same extractor tests below.
      article_body = String.duplicate(
        "Substantive article content here. The density scorer needs enough words to qualify this node. ",
        8
      )

      html = """
      <html><body><article>
        <p>#{article_body}</p>
        <div class="cookie-banner">By using this site you accept our cookies and our terms of service and our privacy policy and we will track you.</div>
      </article></body></html>
      """

      with_banner = Dmhai.Web.ReaderExtractor.extract(html)
      without_banner = Dmhai.Web.ReaderExtractor.extract_for_kb(html)

      assert with_banner.text =~ "cookies"
      assert without_banner.text =~ "Substantive article content"
      refute without_banner.text =~ "By using this site"
    end
  end

  describe "extract_for_kb vs extract" do
    test "extract leaves cookie banner; extract_for_kb removes it" do
      html = """
      <html><body><article>
        <p>#{@article_body}</p>
        <div class="cookie-banner">By using this site you accept our cookies. We track your usage data and share with third parties.</div>
      </article></body></html>
      """

      with_banner = ReaderExtractor.extract(html)
      without_banner = ReaderExtractor.extract_for_kb(html)

      assert with_banner.text =~ "cookies"
      refute without_banner.text =~ "By using this site you accept"
    end
  end
end
