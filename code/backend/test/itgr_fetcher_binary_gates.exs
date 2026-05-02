# Tests for Web.Fetcher's three-gate binary-payload filter.
# See lib/dmh_ai/web/fetcher.ex.
#
# Gate 1 (URL extension blocklist) lives upstream in url.ex and is
# tested via the wiki pipeline; this file covers Gate 2
# (Content-Type) and Gate 3 (NUL-byte body sniff). The gates fire
# inside `Web.Fetcher.attempt/2` so every caller — wiki crawl,
# web_fetch tool, fetch_wiki tool — benefits.

defmodule Itgr.FetcherBinaryGates do
  use ExUnit.Case, async: true

  alias DmhAi.Web.Fetcher

  # Stub HTTP fn — return whatever the test specifies.
  defp http_stub(reply) when is_function(reply, 0) do
    fn _url, _headers -> reply.() end
  end

  defp http_stub(reply) do
    fn _url, _headers -> reply end
  end

  # ─── Gate 2 — Content-Type header ─────────────────────────────────────────

  describe "Content-Type rejection" do
    test "image/png is rejected with non_text_content_type" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>,
        headers: [{"content-type", "image/png"}]
      }})

      assert {:error, {:fetch_failed, {:non_text_content_type, "image/png"}, _, _}} =
               Fetcher.fetch("https://example.com/foo.png", http_fn: stub)
    end

    test "application/pdf is rejected" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   "%PDF-1.4\n…",
        headers: [{"content-type", "application/pdf"}]
      }})

      assert {:error, {:fetch_failed, {:non_text_content_type, "application/pdf"}, _, _}} =
               Fetcher.fetch("https://example.com/doc", http_fn: stub)
    end

    test "application/octet-stream is rejected (server hedge for binary)" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   <<0, 1, 2, 3>>,
        headers: [{"content-type", "application/octet-stream"}]
      }})

      assert {:error, {:fetch_failed, {:non_text_content_type, "application/octet-stream"}, _, _}} =
               Fetcher.fetch("https://example.com/blob", http_fn: stub)
    end

    test "charset parameter is stripped before matching (text/html; charset=utf-8 → ok)" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   "<html><body><p>Hello world this is a long enough article.</p></body></html>",
        headers: [{"content-type", "text/html; charset=utf-8"}]
      }})

      assert {:ok, %{content: content}} =
               Fetcher.fetch("https://example.com/x", http_fn: stub)
      assert is_binary(content) and String.contains?(content, "Hello world")
    end

    test "text/markdown accepted" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   "# Hello\n\nThis is markdown content with enough text to extract usefully.",
        headers: [{"content-type", "text/markdown"}]
      }})

      assert {:ok, _} = Fetcher.fetch("https://example.com/x.md", http_fn: stub)
    end

    test "application/json accepted" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   ~s|{"hello": "world", "items": ["a", "b", "c", "d"]}|,
        headers: [{"content-type", "application/json"}]
      }})

      assert {:ok, _} = Fetcher.fetch("https://example.com/x.json", http_fn: stub)
    end

    test "application/xhtml+xml accepted" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><body>hello world long enough</body></html>",
        headers: [{"content-type", "application/xhtml+xml"}]
      }})

      assert {:ok, _} = Fetcher.fetch("https://example.com/x", http_fn: stub)
    end

    test "Content-Type case is normalised (Image/PNG also rejected)" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   <<137, 80, 78, 71>>,
        headers: [{"Content-Type", "Image/PNG"}]
      }})

      assert {:error, {:fetch_failed, {:non_text_content_type, "image/png"}, _, _}} =
               Fetcher.fetch("https://example.com/foo", http_fn: stub)
    end

    test "headers as a Req-style map (string → list of values)" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   <<137, 80, 78, 71>>,
        headers: %{"content-type" => ["image/png"]}
      }})

      assert {:error, {:fetch_failed, {:non_text_content_type, "image/png"}, _, _}} =
               Fetcher.fetch("https://example.com/foo", http_fn: stub)
    end
  end

  # ─── Gate 3 — body sniff fallback when Content-Type is missing ────────────

  describe "Body sniff fallback (no Content-Type header)" do
    test "NUL byte in first bytes → rejected as binary_body_sniffed" do
      # Synthetic binary payload with NUL bytes near the start.
      body = <<255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0>> <> :binary.copy("X", 600)

      stub = http_stub({:ok, %{
        status: 200,
        body:   body,
        headers: []
      }})

      assert {:error, {:fetch_failed, :binary_body_sniffed, _, _}} =
               Fetcher.fetch("https://example.com/no-ct", http_fn: stub)
    end

    test "clean text body without Content-Type → accepted" do
      stub = http_stub({:ok, %{
        status: 200,
        body:   "<html><body><article><p>This is a perfectly normal HTML page that should pass the sniff.</p></article></body></html>",
        headers: []
      }})

      assert {:ok, %{content: content}} =
               Fetcher.fetch("https://example.com/no-ct", http_fn: stub)
      assert String.contains?(content, "perfectly normal HTML page")
    end

    test "text body with NUL byte beyond sniff window → still accepted (bug-tolerant)" do
      # If a NUL appears past the sniff window, we accept. That's by
      # design — the sniff is a fast heuristic, not a forensic scan.
      pad  = :binary.copy("a", 600)
      body = pad <> <<0>> <> "<html><body>extra</body></html>"

      stub = http_stub({:ok, %{
        status: 200,
        body:   body,
        headers: []
      }})

      # Should reach extraction (no early-bail).
      assert {:ok, _} = Fetcher.fetch("https://example.com/no-ct", http_fn: stub)
    end
  end

  # ─── Header-stated text wins over body content ────────────────────────────

  describe "header takes precedence over body sniff" do
    test "stated text/html with NUL bytes near start → still accepted" do
      # Server says HTML even though the body has NUL early. We trust
      # the header (binary-content-type rejection wins for binaries;
      # for text-stated, we don't second-guess).
      body = "<html>\0<body>weird but the server said HTML</body></html>"

      stub = http_stub({:ok, %{
        status: 200,
        body:   body,
        headers: [{"content-type", "text/html"}]
      }})

      # Extraction may strip the NUL or yield short text; what we
      # check is that we don't reject before extraction.
      result = Fetcher.fetch("https://example.com/x", http_fn: stub)
      refute match?({:error, {:fetch_failed, :binary_body_sniffed, _, _}}, result)
    end
  end
end
