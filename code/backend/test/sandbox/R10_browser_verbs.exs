# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R10 — Browser action verb coverage.
#
# Drives every daemon verb at least once against a real Chromium +
# Playwright stack hitting `file:///test_fixtures/browser_pages/...`
# fixtures bind-mounted by `scripts/test.sandbox.sh`.
#
# Verbs covered:
#   - Navigation:    navigate, back
#   - Observation:   observe (enumerate + annotate + screenshot)
#   - Actions:       click {index}, type {index}, key, scroll_by
#   - Content:       extract_text (body + indexed)
#   - Soft errors:   stale_index (post-mutation, post-navigate)
#   - Misc:          wait, ping
#
# Each verb is tested at the daemon contract level — we drive
# `DaemonClient.call/3` directly and verify the daemon's return
# envelope. Visible page-state effects (e.g. "did the click flip
# the #out div?") are verified via a follow-up `extract_text`
# rather than introspecting Playwright internals.
#
# Fixture interactives (top-to-bottom-left-to-right order):
#   idx 1 — <input id="txt" placeholder="type here">
#   idx 2 — <button id="btn">Submit</button>     (onclick → #out = "CLICKED:" + value)
#   idx 3 — <a id="link" href="#bottom">Jump to bottom</a>
# The wrapping <form>'s onsubmit handler fires on implicit-Enter:
#   → #out = "SUBMITTED:" + value

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R10BrowserVerbs do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Browser.DaemonClient

  @fixture_url "file:///test_fixtures/browser_pages/01_basic_page.html"
  @desktop_viewport %{w: 1024, h: 768, is_mobile: false}

  # ── navigate ──────────────────────────────────────────────────────────────

  test "navigate returns url + title + status", ctx do
    daemon_ctx = ctx_for(ctx)
    assert {:ok, %{"url" => url, "title" => title}} =
             DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)

    assert String.ends_with?(url, "/01_basic_page.html")
    assert title == "Basic page"
  end

  # ── observe ───────────────────────────────────────────────────────────────

  test "observe returns annotated JPEG + element descriptor list", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)

    assert {:ok, snap} = DaemonClient.call("observe", %{}, daemon_ctx)

    # Image: JPEG SOI magic bytes after b64 decode.
    assert is_binary(snap["image_b64"]) and byte_size(snap["image_b64"]) > 0
    assert snap["mime"] == "image/jpeg"
    {:ok, raw} = Base.decode64(snap["image_b64"])
    assert binary_part(raw, 0, 3) == <<0xFF, 0xD8, 0xFF>>

    # Viewport / metadata.
    assert snap["viewport"] == %{"w" => @desktop_viewport.w, "h" => @desktop_viewport.h}
    assert snap["title"] == "Basic page"

    # Elements: top-to-bottom-left-to-right order. The first three are
    # the fixture's interactives; further elements may be present (the
    # filler region's anchor-by-href, etc.) but the first three are
    # deterministic.
    elements = snap["elements"]
    assert is_list(elements) and length(elements) >= 3

    [e1, e2, e3 | _] = elements

    assert e1["idx"] == 1
    assert e1["tag"] == "input"
    assert e1["placeholder"] == "type here"

    assert e2["idx"] == 2
    assert e2["tag"] == "button"
    assert String.contains?(e2["text"], "Submit")

    assert e3["idx"] == 3
    assert e3["tag"] == "a"
    assert String.contains?(e3["text"], "Jump to bottom")
  end

  # ── click {index} ─────────────────────────────────────────────────────────

  test "click {index} fires the indexed button's onclick handler", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)
    {:ok, _} = DaemonClient.call("observe", %{}, daemon_ctx)

    assert {:ok, %{"clicked" => 2, "tag" => "button"}} =
             DaemonClient.call("click", %{index: 2}, daemon_ctx)

    # The onclick handler copies #txt's value into #out with a CLICKED: prefix.
    {:ok, %{"text" => text}} = DaemonClient.call("extract_text", %{}, daemon_ctx)
    assert text =~ "CLICKED:"
  end

  # ── type {index} ──────────────────────────────────────────────────────────

  test "type {index, text} types into the indexed input", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)
    {:ok, _} = DaemonClient.call("observe", %{}, daemon_ctx)

    assert {:ok, %{"typed" => 1, "submitted" => false}} =
             DaemonClient.call("type", %{index: 1, text: "hello"}, daemon_ctx)

    # type invalidated marks → re-observe before the next indexed verb.
    {:ok, _} = DaemonClient.call("observe", %{}, daemon_ctx)
    {:ok, _} = DaemonClient.call("click", %{index: 2}, daemon_ctx)

    {:ok, %{"text" => text}} = DaemonClient.call("extract_text", %{}, daemon_ctx)
    assert String.contains?(text, "CLICKED:hello")
  end

  test "type {index, text, submit: true} presses Enter and submits the form", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)
    {:ok, _} = DaemonClient.call("observe", %{}, daemon_ctx)

    assert {:ok, %{"typed" => 1, "submitted" => true}} =
             DaemonClient.call("type",
               %{index: 1, text: "world", submit: true}, daemon_ctx)

    # Implicit form submission (single text input, no submit button)
    # invokes onsubmit → #out gets the SUBMITTED: prefix.
    {:ok, %{"text" => text}} = DaemonClient.call("extract_text", %{}, daemon_ctx)
    assert String.contains?(text, "SUBMITTED:world")
  end

  # ── stale_index ───────────────────────────────────────────────────────────

  test "click {index} after a mutating verb without re-observe → stale_index", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)
    {:ok, _} = DaemonClient.call("observe", %{}, daemon_ctx)

    # First click invalidates the daemon's idx → ElementHandle map.
    {:ok, _} = DaemonClient.call("click", %{index: 2}, daemon_ctx)

    # Second click without an intervening observe → soft-error envelope.
    assert {:error, {:daemon_error, %{type: "stale_index"}}} =
             DaemonClient.call("click", %{index: 2}, daemon_ctx)
  end

  test "click {index} after navigate without observe → stale_index", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)
    {:ok, _} = DaemonClient.call("observe", %{}, daemon_ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: "about:blank"}, daemon_ctx)

    assert {:error, {:daemon_error, %{type: "stale_index"}}} =
             DaemonClient.call("click", %{index: 1}, daemon_ctx)
  end

  # ── key ───────────────────────────────────────────────────────────────────

  test "key presses a named key", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)

    assert {:ok, %{"pressed" => "Tab"}} =
             DaemonClient.call("key", %{name: "Tab"}, daemon_ctx)
  end

  # ── scroll_by ─────────────────────────────────────────────────────────────

  test "scroll_by returns the scroll delta", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)

    assert {:ok, %{"scrolled_by" => %{"dx" => 0, "dy" => 400}}} =
             DaemonClient.call("scroll_by", %{dx: 0, dy: 400}, daemon_ctx)
  end

  # ── back ──────────────────────────────────────────────────────────────────

  test "back returns to the previous page", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: "about:blank"}, daemon_ctx)

    assert {:ok, %{"url" => url}} =
             DaemonClient.call("back", %{}, daemon_ctx)

    assert String.ends_with?(url, "/01_basic_page.html")
  end

  # ── extract_text ──────────────────────────────────────────────────────────

  test "extract_text (no index) returns body text", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)

    assert {:ok, %{"text" => text, "matches" => n}} =
             DaemonClient.call("extract_text", %{}, daemon_ctx)

    assert n >= 1
    assert String.contains?(text, "R10 verb coverage")
  end

  test "extract_text {index} returns the indexed element's inner text", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)
    {:ok, _} = DaemonClient.call("observe", %{}, daemon_ctx)

    # idx 2 = the Submit button
    assert {:ok, %{"text" => text}} =
             DaemonClient.call("extract_text", %{index: 2}, daemon_ctx)

    assert String.contains?(text, "Submit")
  end

  # ── wait ──────────────────────────────────────────────────────────────────

  test "wait blocks for the given ms (capped 3000)", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)

    t0 = System.monotonic_time(:millisecond)
    assert {:ok, %{"waited" => 200}} =
             DaemonClient.call("wait", %{ms: 200}, daemon_ctx)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert elapsed >= 200
    assert elapsed < 1500
  end

  test "wait clamps to the 3000ms cap", ctx do
    daemon_ctx = ctx_for(ctx)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_ctx)

    assert {:ok, %{"waited" => 3000}} =
             DaemonClient.call("wait", %{ms: 9_999}, daemon_ctx)
  end

  # ── ping ──────────────────────────────────────────────────────────────────

  test "ping returns pong + uptime", ctx do
    daemon_ctx = ctx_for(ctx)
    assert {:ok, %{"pong" => true, "uptime_s" => uptime}} =
             DaemonClient.call("ping", %{}, daemon_ctx)

    assert is_integer(uptime) and uptime >= 0
  end

  # ── per-session isolation ─────────────────────────────────────────────────

  test "different session_id gets a different Page (own viewport)", _ctx do
    user_id = "u_r10_iso_" <> rand()
    email = "r10_iso_" <> rand() <> "@dmhai.test"

    s_a = "s_a_" <> rand()
    s_b = "s_b_" <> rand()

    daemon_a = %{user_id: user_id, session_id: s_a, email: email,
                  viewport: %{w: 800, h: 600, is_mobile: false}}
    daemon_b = %{user_id: user_id, session_id: s_b, email: email,
                  viewport: %{w: 390, h: 844, is_mobile: true}}

    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_a)
    {:ok, _} = DaemonClient.call("navigate", %{url: @fixture_url}, daemon_b)

    {:ok, snap_a} = DaemonClient.call("observe", %{}, daemon_a)
    {:ok, snap_b} = DaemonClient.call("observe", %{}, daemon_b)

    assert snap_a["viewport"] == %{"w" => 800, "h" => 600}
    assert snap_b["viewport"] == %{"w" => 390, "h" => 844}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp ctx_for(_ctx) do
    suffix = rand()
    %{
      user_id: "u_r10_#{suffix}",
      session_id: "s_r10_#{suffix}",
      email: "r10_#{suffix}@dmhai.test",
      viewport: @desktop_viewport
    }
  end

  defp rand, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
