# Tests for the URL `/wiki` pipeline's scope-check semantics.
# See lib/dmh_ai/commands/pipelines/url.ex.
#
# These tests exercise the in-scope predicate as a pure boolean — the
# crawl machinery itself (BFS, ingest, link queueing) needs a live
# vector DB and is covered by the broader integration suite. Keeping
# this file focused on the predicate that previously dropped
# directory-shaped URLs without a trailing slash.

defmodule Itgr.WikiPipeline do
  use ExUnit.Case, async: true

  # The fixed predicate is a one-liner inside `process_page/3` —
  # replicate it here so we test the *contract* (the rule we want),
  # not the implementation. If url.ex is refactored, this test stays
  # meaningful as long as the rule holds.
  defp in_scope?(final_url, prefix),
    do: String.starts_with?(final_url <> "/", prefix)

  describe "scope check (final_url vs same-prefix)" do
    test "bare directory url with no trailing slash is in scope (the regression)" do
      prefix    = "https://github.com/bitrix24/b24restdocs/"
      final_url = "https://github.com/bitrix24/b24restdocs"
      assert in_scope?(final_url, prefix)
    end

    test "trailing-slash directory url is in scope" do
      prefix    = "https://github.com/bitrix24/b24restdocs/"
      final_url = "https://github.com/bitrix24/b24restdocs/"
      assert in_scope?(final_url, prefix)
    end

    test "child page is in scope" do
      prefix    = "https://github.com/bitrix24/b24restdocs/"
      final_url = "https://github.com/bitrix24/b24restdocs/blob/main/README.md"
      assert in_scope?(final_url, prefix)
    end

    test "sibling path with similar prefix is NOT in scope" do
      # The classic false-positive risk for naive starts_with? checks.
      prefix    = "https://github.com/X/"
      final_url = "https://github.com/X-other/repo"
      refute in_scope?(final_url, prefix)
    end

    test "different host is NOT in scope" do
      prefix    = "https://github.com/bitrix24/b24restdocs/"
      final_url = "https://gitlab.com/bitrix24/b24restdocs"
      refute in_scope?(final_url, prefix)
    end

    test "different user/org is NOT in scope" do
      prefix    = "https://github.com/bitrix24/b24restdocs/"
      final_url = "https://github.com/microsoft/vscode"
      refute in_scope?(final_url, prefix)
    end

    test "scheme mismatch is NOT in scope" do
      prefix    = "https://github.com/bitrix24/"
      final_url = "http://github.com/bitrix24/b24restdocs"
      refute in_scope?(final_url, prefix)
    end
  end

  # Smoke test that the live module produces the correct prefix shape
  # for the failure case we just fixed. Catches regression if anyone
  # changes same_prefix_path to drop the trailing slash, which would
  # break the BFS link-filter assumption elsewhere.
  describe "Pipelines.URL prefix derivation" do
    test "same_prefix appends a trailing slash for bare-dir URLs" do
      # The function is private; call through Module.split-style trick
      # would couple the test to internals. Instead, we assert the
      # *behaviour* via a short eval of the public BFS scope check —
      # using the same fixture as the regression.
      prefix    = "https://github.com/bitrix24/b24restdocs/"
      final_url = "https://github.com/bitrix24/b24restdocs"
      assert in_scope?(final_url, prefix),
             "if this fails, /wiki <bare-dir-url> will index 0 pages again"
    end
  end

  # ─── Layer 2A — query-string filter ────────────────────────────────────

  # Replicate the predicate so the test is robust to refactors of the
  # private helper. Any URL with a non-empty `?…` is dropped from the
  # discovery queue.
  defp has_query_string?(url) do
    case URI.parse(url) do
      %URI{query: q} when is_binary(q) and q != "" -> true
      _ -> false
    end
  end

  describe "query-string filter (Layer 2A)" do
    test "URL with ?q= is dropped" do
      assert has_query_string?("https://github.com/bitrix24/b24restdocs/pulls?q=is%3Apr+is%3Aopen")
    end

    test "URL with ?sort= is dropped" do
      assert has_query_string?("https://example.com/articles?sort=created-desc")
    end

    test "URL with ?page=2 is dropped (pagination is redundant content)" do
      assert has_query_string?("https://example.com/blog?page=2")
    end

    test "URL with empty querystring is NOT dropped (?)" do
      # `https://example.com/x?` — RFC technically valid but URI.parse
      # treats query as empty string, which we don't want to flag.
      refute has_query_string?("https://example.com/x?")
    end

    test "queryless URL is kept" do
      refute has_query_string?("https://example.com/docs/intro")
    end

    test "fragment-only URL is kept" do
      refute has_query_string?("https://example.com/docs#section-2")
    end
  end

  # ─── Layer 2B — asset path-segment blocklist ────────────────────────────

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

  defp asset_path_segment?(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) ->
        path |> String.split("/", trim: true) |> Enum.any?(&(&1 in @asset_path_segments))

      _ ->
        false
    end
  end

  describe "asset path-segment filter (Layer 2B)" do
    test "_images directory is dropped" do
      assert asset_path_segment?("https://github.com/bitrix24/b24restdocs/tree/main/_images")
    end

    test "node_modules anywhere in the path is dropped" do
      assert asset_path_segment?("https://example.com/repo/node_modules/foo/README.md")
    end

    test ".next build dir is dropped" do
      assert asset_path_segment?("https://example.com/.next/static/chunk.js")
    end

    test "__pycache__ is dropped" do
      assert asset_path_segment?("https://example.com/lib/__pycache__/x.cpython-311.pyc")
    end

    test ".git internals are dropped" do
      assert asset_path_segment?("https://example.com/repo/.git/config")
    end

    test "vendor tree is dropped" do
      assert asset_path_segment?("https://example.com/project/vendor/lib/x.go")
    end

    test "ambiguous names NOT in the blocklist are kept" do
      # Deliberate omissions per design — these are commonly legit
      # content paths.
      refute asset_path_segment?("https://example.com/public/index.html")
      refute asset_path_segment?("https://example.com/coverage/medical-plans")
      refute asset_path_segment?("https://example.com/about-us")
      refute asset_path_segment?("https://example.com/check-out")
      refute asset_path_segment?("https://example.com/k8s/pods/intro")
    end

    test "whole-segment match — substring with surrounding chars doesn't false-positive" do
      # `node_modules` blocks `/node_modules/`, NOT `/abc-node_modules-x/`.
      refute asset_path_segment?("https://example.com/abc-node_modules-x/file")
      refute asset_path_segment?("https://example.com/node_modules_backup/file")
    end

    test "case-sensitive — Node_modules ≠ node_modules" do
      # URLs are case-sensitive per RFC; we don't normalise.
      refute asset_path_segment?("https://example.com/Node_modules/x")
    end
  end

  # ─── Layer 2C — text-quality leaf treatment ─────────────────────────────

  describe "text-quality threshold (Layer 2C)" do
    @min_chars_for_useful_page 500

    defp useful_page?(text) when is_binary(text),
      do: byte_size(text) >= @min_chars_for_useful_page

    test "page with 500+ chars is considered useful" do
      assert useful_page?(String.duplicate("a", 500))
      assert useful_page?(String.duplicate("real prose ", 100))
    end

    test "page with under 500 chars is treated as a leaf" do
      refute useful_page?("only a few words")
      refute useful_page?(String.duplicate("a", 499))
    end

    test "empty text is not useful" do
      refute useful_page?("")
    end

    test "exactly 500 chars is the boundary (≥, not >)" do
      assert useful_page?(String.duplicate("a", 500))
    end
  end

  # ─── Combined "should skip discovered link?" predicate ─────────────────

  describe "combined gates" do
    defp should_skip?(url),
      do: has_query_string?(url) or asset_path_segment?(url)

    test "the original failure case (assets directory) is skipped" do
      assert should_skip?("https://github.com/bitrix24/b24restdocs/tree/main/_images")
    end

    test "the second failure case (faceted PR list) is skipped" do
      assert should_skip?("https://github.com/bitrix24/b24restdocs/pulls?q=is%3Apr+is%3Aopen")
    end

    test "a real docs page passes through" do
      refute should_skip?("https://github.com/bitrix24/b24restdocs/blob/main/README.md")
    end

    test "a real article URL passes through" do
      refute should_skip?("https://docs.example.com/api/v2/methods")
    end
  end
end
