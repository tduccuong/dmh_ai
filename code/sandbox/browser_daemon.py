#!/usr/bin/env python3
# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com
"""
DMH-AI browser daemon — annotated-vision (Navigator) architecture.

One long-lived Playwright process holding ONE Chromium instance for
the whole deployment. Two-layer state model that maps onto
Playwright's own primitives:

  BrowserContext (one per `user_id`)
    owns persistent surface: cookies, localStorage, sessionStorage,
    auth tokens. Backed by .browser_state.json on disk. Two chat
    sessions for the same user share this — login persists.

  SessionContext (one per `(user_id, session_id)`, materialised as
  a Playwright Page within the user's BrowserContext)
    owns ephemeral surface: viewport, current URL, scroll, in-flight
    nav. Viewport comes from the FE-reported chat-tab dimensions.

The action surface is Set-of-Marks: `observe` enumerates the visible
interactive elements, paints a magenta box + numeric label around
each in an injected overlay, screenshots the viewport, then strips
the overlay. The Navigator picks an index. Subsequent `click {index}`
/ `type {index, text}` / `extract_text {index}` look the element up
via a stamped `data-dmh-idx` attribute and act on it through
Playwright. No pixel coordinates ever cross the wire.

Listens on a Unix socket at /var/run/dmh-browser/daemon.sock with
newline-JSON request/response framing. One connection per request.

See arch_wiki/dmh_ai/architecture.md §"Browser tools" for the
command surface, the IPC protocol, and current limitations.
"""

import asyncio
import json
import os
import signal
import sys
import time
import traceback

from playwright.async_api import (
    async_playwright,
    Error as PWError,
    TimeoutError as PWTimeoutError,
)

# ── Tuning ────────────────────────────────────────────────────────────────────

SOCK_PATH = os.environ.get("BROWSER_SOCK_PATH", "/var/run/dmh-browser/daemon.sock")

# Idle shutdown: kill Chromium + exit if no requests for this long.
# start.sh's supervisor relaunches us on next call. Pi-class hosts
# reclaim ~150–250 MB of RSS this way.
IDLE_SHUTDOWN_S = int(os.environ.get("BROWSER_IDLE_SHUTDOWN_S", "1800"))

# Workspace root. Same host directory mounted at the same path on
# master AND sandbox, so a path built on master is consumable here
# without translation. Per-user Playwright storage_state lives at
# /data/user_workspaces/<email>/.browser_state.json.
WORK_ROOT = "/data/user_workspaces"

# Per-command default timeout (ms). Overridable per-call via args.timeout.
DEFAULT_CMD_TIMEOUT_MS = 15_000

# Per-action default timeout. Tighter than DEFAULT_CMD_TIMEOUT_MS
# because actions act on the already-rendered page; if a coord click
# misses there's no point waiting 15 s. Matches `browserActionTimeoutMs`
# in AgentSettings (3000ms default).
DEFAULT_ACTION_TIMEOUT_MS = 3_000

# How often the idle watchdog wakes up to check the timer.
WATCHDOG_INTERVAL_S = 30

# Safety viewport when no client_viewport was forwarded (older FE,
# direct API caller). Small enough to keep screenshots cheap; mobile
# class so most sites render their simpler layout.
FALLBACK_VIEWPORT = {"w": 360, "h": 640, "is_mobile": True}

# User-Agent templates by device class. Real Chrome strings — modern
# anti-bot SDKs that check UA don't get an extra signal from this.
UA_DESKTOP = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
UA_MOBILE = (
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
)

# ── Set-of-Marks tunables ─────────────────────────────────────────────────────
# Mirror the AgentSettings keys (`browser*`) on the master side. Env-driven
# so a stage operator can override without rebuilding the image.

# Hard cap on enumerated interactives per observe. Commercial sites have
# 100-300 visible interactives once nav + footer + filters are counted;
# beyond ~80 the annotated image is unreadable and the ELEMENTS list
# bloats the prompt. Overflow keeps the candidates whose centres are
# closest to the viewport centre — chrome elements drop, in-frame ones
# stay.
MAX_INTERACTIVES = int(os.environ.get("BROWSER_MAX_INTERACTIVES_PER_TURN", "80"))

# Bounding-rect minimum (CSS pixels) to be eligible for indexing.
# Below this we're enumerating 1×1 tracker pixels and zero-size hidden
# controls, neither of which the model can actually act on.
MIN_INTERACTIVE_SIZE_PX = int(os.environ.get("BROWSER_MIN_INTERACTIVE_SIZE_PX", "6"))

# Box outline width drawn around each indexed element.
ANNOTATION_STROKE_PX = int(os.environ.get("BROWSER_ANNOTATION_STROKE_PX", "2"))

# Height of the magenta-fill numeric label at top-left of each box.
ANNOTATION_LABEL_HEIGHT_PX = int(os.environ.get("BROWSER_ANNOTATION_LABEL_HEIGHT_PX", "14"))

# Drop candidates whose rect covers more than this fraction of the
# viewport. Modal backdrops, full-page React roots, and "click-anywhere
# to dismiss" overlays are the typical hits. They convey no actionable
# signal — the model should target the specific buttons inside the
# modal (which are enumerated separately) — and they bury the smaller
# elements visually under a huge magenta rectangle. Expressed as a
# fraction so the filter scales with viewport size.
MAX_CANDIDATE_AREA_FRAC = float(os.environ.get("BROWSER_MAX_CANDIDATE_AREA_FRAC", "0.7"))

# The synthetic attribute we stamp onto each enumerated element. The
# attribute IS the cache: a subsequent `click {index: N}` resolves via
# `page.query_selector('[data-dmh-idx="N"]')`. State-mutating verbs
# clear all stamps so a stale `click` returns `{error: "stale_index"}`.
INDEXED_ATTR = "data-dmh-idx"


# ── JS programs executed in the page context ─────────────────────────────────

# Enumerate, filter, sort, cap, stamp. Returns the descriptor list
# (one map per element) that ships back to the Loop alongside the
# annotated screenshot. The same elements carry a `data-dmh-idx="N"`
# attribute server-side after this runs, which `_cmd_click` etc. look
# up via `page.query_selector`.
_OBSERVE_JS = r"""
(opts) => {
  const ATTR         = opts.indexed_attr;
  const MAX          = opts.max_elements;
  const MIN          = opts.min_size_px;
  const MAX_AREA_FRAC = opts.max_area_frac;

  // Clear any stamps left over from a previous observe. Always do this
  // FIRST so we never accidentally re-use last turn's index → element
  // map if the page partially re-rendered.
  for (const el of document.querySelectorAll('[' + ATTR + ']')) {
    el.removeAttribute(ATTR);
  }

  const vw = window.innerWidth;
  const vh = window.innerHeight;

  const NATIVE_TAGS = new Set(['a','button','input','select','textarea','summary']);
  const SEMANTIC_ROLES = new Set([
    'button','link','checkbox','radio','tab','menuitem','option','switch'
  ]);

  function isInsideChrome(el) {
    // Footer-chrome filter. Sites mark their footers explicitly via
    // <footer> / role="contentinfo"; the descendants are policy /
    // terms / contact / sitemap links that are NEVER part of an
    // action flow. They balloon the ELEMENTS list (60+ items on a
    // typical commerce footer) and the model picks them blindly.
    // Top <nav> stays eligible — sites use it for primary tab
    // navigation that IS sometimes part of the task path.
    let p = el;
    while (p && p !== document.body) {
      const tag = p.tagName ? p.tagName.toLowerCase() : '';
      if (tag === 'footer') return true;
      const role = p.getAttribute ? p.getAttribute('role') : null;
      if (role === 'contentinfo') return true;
      p = p.parentElement;
    }
    return false;
  }

  function isInteractive(el, cs) {
    // Drop SVG inner shapes (<path>, <circle>, <rect>, <g>, <use>, …).
    // They inherit `cursor: pointer` from a clickable <svg> wrapper
    // but aren't directly clickable in HTML terms — Playwright's
    // ElementHandle.click() on a <path> bubbles to the <svg>'s
    // handler, so we want the model to target the <svg> instead.
    // The <svg> wrapper itself stays eligible (it has its own
    // tagName 'svg' and we don't bail on it here).
    if (el.namespaceURI === 'http://www.w3.org/2000/svg' && el.tagName.toLowerCase() !== 'svg') {
      return false;
    }
    if (isInsideChrome(el)) return false;
    const tag = el.tagName.toLowerCase();
    if (NATIVE_TAGS.has(tag)) {
      // <a> without href isn't navigable; sites use bare <a> as
      // typography sometimes.
      if (tag === 'a' && !el.hasAttribute('href')) return false;
      // <input type="hidden"> isn't user-interactive.
      if (tag === 'input' && (el.getAttribute('type') || '').toLowerCase() === 'hidden') return false;
      return true;
    }
    const role = el.getAttribute('role');
    if (role && SEMANTIC_ROLES.has(role)) return true;
    const ti = el.getAttribute('tabindex');
    if (ti !== null && parseInt(ti, 10) >= 0) return true;
    if (typeof el.onclick === 'function') return true;
    if (cs.cursor === 'pointer') return true;
    return false;
  }

  function rectIntersectsViewport(r) {
    return !(r.right < 0 || r.bottom < 0 || r.left > vw || r.top > vh);
  }

  // Single DOM walk — getComputedStyle is the expensive call so we
  // do it once and pass it to both predicates. Querying every
  // element is fine even on heavy pages (~1 ms per 1000 nodes).
  const VIEWPORT_AREA = vw * vh;
  const MAX_AREA = VIEWPORT_AREA * MAX_AREA_FRAC;
  const raw = [];
  for (const el of document.querySelectorAll('*')) {
    let cs;
    try { cs = window.getComputedStyle(el); } catch (_) { continue; }
    if (cs.display === 'none') continue;
    if (cs.visibility === 'hidden' || cs.visibility === 'collapse') continue;
    if (parseFloat(cs.opacity) === 0) continue;

    const r = el.getBoundingClientRect();
    if (r.width < MIN || r.height < MIN) continue;
    if (!rectIntersectsViewport(r)) continue;
    // Drop modal backdrops, React roots with cursor:pointer, and
    // "click-anywhere" overlays — they cover most of the viewport
    // and convey no actionable signal. The buttons inside the modal
    // get enumerated separately and are the real click target.
    if (r.width * r.height > MAX_AREA) continue;
    if (!isInteractive(el, cs)) continue;

    raw.push({ el, r });
  }

  // De-duplicate by ancestry. The rule has two clauses, applied in
  // this order to each candidate X:
  //
  //   (1) If X is a NATIVE interactive (button, a, input, …), always
  //       keep it. Its descendants are inner labels (e.g. <h5>Accept</h5>
  //       inside <button>) — the model should target the semantic
  //       wrapper, not the typography element.
  //   (2) If X is non-native (a div with cursor:pointer / onclick),
  //       drop it if any DESCENDANT is also a candidate. The
  //       descendant is more specific; clicking it bubbles to X's
  //       handler anyway.
  //   (3) Drop X if any ANCESTOR is a native candidate. The native
  //       ancestor is the real click target; X is redundant.
  //
  // O(N × avg-descendants + N × avg-ancestor-depth) — on a 200-
  // candidate page this is ~10 ms.
  const candidateSet = new Set(raw.map(c => c.el));
  function isNativeTag(el) { return NATIVE_TAGS.has(el.tagName.toLowerCase()); }
  const candidates = raw.filter(c => {
    const native = isNativeTag(c.el);
    if (!native) {
      // (2) non-native dropped if any descendant is a candidate
      for (const d of c.el.querySelectorAll('*')) {
        if (candidateSet.has(d)) return false;
      }
    }
    // (3) drop anything whose ancestor is a native candidate
    let p = c.el.parentElement;
    while (p) {
      if (candidateSet.has(p) && isNativeTag(p)) return false;
      p = p.parentElement;
    }
    return true;
  });

  // Sort top-to-bottom, left-to-right by top-left corner.
  candidates.sort((a, b) => (a.r.top - b.r.top) || (a.r.left - b.r.left));

  // Cap at MAX, keeping the candidates whose CENTRES are closest to
  // the viewport centre. Commercial sites bury action UI in the main
  // body and noise (nav, footer, social rail) at the edges; the
  // centre-bias preserves the actionable region.
  let kept = candidates;
  if (candidates.length > MAX) {
    const cx = vw / 2, cy = vh / 2;
    const scored = candidates.map((c, i) => {
      const ex = c.r.left + c.r.width / 2;
      const ey = c.r.top + c.r.height / 2;
      const d = Math.hypot(ex - cx, ey - cy);
      return { c, d, i };
    });
    scored.sort((a, b) => a.d - b.d);
    const winnerIdx = new Set(scored.slice(0, MAX).map(s => s.i));
    kept = candidates.filter((_, i) => winnerIdx.has(i));
  }

  function describe(el) {
    const tag = el.tagName.toLowerCase();
    let text = '';
    if (tag === 'input' || tag === 'textarea') {
      text = (el.value || '').toString();
    } else if (tag === 'select') {
      const opt = el.options && el.options[el.selectedIndex];
      text = opt ? (opt.text || '') : '';
    } else {
      text = (el.innerText || el.textContent || '').toString();
    }
    text = text.replace(/\s+/g, ' ').trim();
    if (text.length > 40) text = text.slice(0, 40) + '…';
    return text;
  }

  // For inputs / textareas / selects, recover the human-visible label
  // text. Order matters: explicit aria > <label for=…> > wrapping
  // <label> > nearest preceding text node. The first match wins.
  // Returns a short trimmed string, or '' if no label can be
  // identified. The model uses this to distinguish identically-tagged
  // inputs (e.g. From / To / Departure date / Return Date all share
  // <input type="text">).
  function findLabel(el) {
    const aria = el.getAttribute('aria-label');
    if (aria) return aria.replace(/\s+/g, ' ').trim();

    const labelledby = el.getAttribute('aria-labelledby');
    if (labelledby) {
      const parts = [];
      for (const id of labelledby.split(/\s+/)) {
        const ref = document.getElementById(id);
        if (ref) parts.push((ref.innerText || ref.textContent || '').trim());
      }
      const j = parts.filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
      if (j) return j;
    }

    const id = el.getAttribute('id');
    if (id) {
      // CSS.escape would be safer but is not strictly needed for the
      // common case of alphanumeric ids — fall back gracefully if the
      // selector throws.
      try {
        const lab = document.querySelector('label[for="' + id.replace(/"/g, '\\"') + '"]');
        if (lab) {
          const t = (lab.innerText || lab.textContent || '').replace(/\s+/g, ' ').trim();
          if (t) return t;
        }
      } catch (_) {}
    }

    // Wrapping <label>: walk up to find an ancestor <label>.
    let p = el.parentElement;
    while (p && p !== document.body) {
      if (p.tagName && p.tagName.toLowerCase() === 'label') {
        // Use only the <label>'s OWN text, not the input's value
        // (cloneNode strip-and-text avoids that).
        const clone = p.cloneNode(true);
        for (const inner of clone.querySelectorAll('input,textarea,select')) {
          inner.remove();
        }
        const t = (clone.innerText || clone.textContent || '').replace(/\s+/g, ' ').trim();
        if (t) return t;
        break;
      }
      p = p.parentElement;
    }

    // Form-control container pattern (Bootstrap form-group, MUI
    // FormControl, AntD form-item, raw <div><label/><input/></div>):
    // the <label> is a SIBLING of the input's parent or grandparent,
    // not an ancestor. Walk up at most 3 levels but STOP at the
    // first ancestor containing another input — once two inputs
    // share a container the local label is ambiguous and we'd risk
    // mis-attributing one input's label to another. At each level
    // look for a descendant <label> that isn't already an ancestor
    // of the input (which we handled in the wrapping-label step).
    let anc = el.parentElement;
    let hops = 0;
    while (anc && hops < 3) {
      const inputCount = anc.querySelectorAll('input,textarea,select').length;
      if (inputCount > 1 && hops > 0) break;
      const lab = anc.querySelector(':scope > label, :scope > * > label');
      if (lab && !lab.contains(el)) {
        const t = (lab.innerText || lab.textContent || '').replace(/\s+/g, ' ').trim();
        if (t) return t;
      }
      anc = anc.parentElement;
      hops += 1;
    }

    // Last resort: nearest preceding sibling with visible text. Covers
    // sites that put a free-floating <span> label above the input
    // without binding them via for/id.
    let sib = el.previousElementSibling;
    while (sib) {
      const t = (sib.innerText || sib.textContent || '').replace(/\s+/g, ' ').trim();
      if (t && t.length < 60) return t;
      sib = sib.previousElementSibling;
    }
    return '';
  }

  const out = [];
  kept.forEach((cand, i) => {
    const idx = i + 1;
    const el = cand.el;
    const r = cand.r;
    el.setAttribute(ATTR, String(idx));
    const entry = {
      idx,
      tag: el.tagName.toLowerCase(),
      text: describe(el),
      x: Math.round(r.left),
      y: Math.round(r.top),
      w: Math.round(r.width),
      h: Math.round(r.height),
    };
    const role = el.getAttribute('role');     if (role) entry.role = role;
    const type = el.getAttribute('type');     if (type) entry.type = type;
    const ph   = el.getAttribute('placeholder'); if (ph) entry.placeholder = ph;
    if ((entry.tag === 'input' || entry.tag === 'textarea' || entry.tag === 'select') && el.value) {
      entry.value = String(el.value).slice(0, 40);
    }
    // Recover the input's visible label so the model can distinguish
    // identically-tagged inputs (From / To / Departure date / …).
    if (entry.tag === 'input' || entry.tag === 'textarea' || entry.tag === 'select') {
      const lbl = findLabel(el);
      if (lbl && lbl.length <= 60) entry.label = lbl;
      else if (lbl) entry.label = lbl.slice(0, 60) + '…';
    }
    out.push(entry);
  });
  return out;
}
"""

# Paint the magenta overlay. Reads stamped elements directly, draws
# one absolute-positioned <div> per box + one per label, anchored to
# the wrapper which is `pointer-events: none` so it never absorbs a
# click. `z-index: 2147483647` is INT32_MAX — sites' own modals
# rarely climb past 100000.
_OVERLAY_INJECT_JS = r"""
(opts) => {
  const ATTR   = opts.indexed_attr;
  const STROKE = opts.stroke_px;
  const LH     = opts.label_h_px;

  const old = document.getElementById('__dmh_overlay');
  if (old) old.remove();

  const wrap = document.createElement('div');
  wrap.id = '__dmh_overlay';
  wrap.style.cssText = (
    'position:fixed;top:0;left:0;width:100%;height:100%;' +
    'pointer-events:none;z-index:2147483647;'
  );

  for (const el of document.querySelectorAll('[' + ATTR + ']')) {
    const idx = el.getAttribute(ATTR);
    const r = el.getBoundingClientRect();

    const box = document.createElement('div');
    box.style.cssText = (
      'position:fixed;' +
      'left:' + r.left + 'px;' +
      'top:'  + r.top  + 'px;' +
      'width:'  + r.width  + 'px;' +
      'height:' + r.height + 'px;' +
      'border:' + STROKE + 'px solid #FF00FF;' +
      'box-sizing:border-box;pointer-events:none;'
    );
    wrap.appendChild(box);

    // Place label outside the box if there's room above it; otherwise
    // inside the top edge. Magenta fill, white text, monospace.
    const labelTop = r.top >= LH ? r.top - LH : r.top;
    const label = document.createElement('div');
    label.textContent = idx;
    label.style.cssText = (
      'position:fixed;' +
      'left:' + r.left + 'px;' +
      'top:'  + labelTop + 'px;' +
      'height:' + LH + 'px;' +
      'min-width:' + LH + 'px;' +
      'padding:0 4px;' +
      'background:#FF00FF;color:#FFFFFF;' +
      'font:bold ' + (LH - 2) + 'px/' + LH + 'px monospace;' +
      'text-align:center;pointer-events:none;'
    );
    wrap.appendChild(label);
  }

  document.body.appendChild(wrap);
}
"""

_OVERLAY_REMOVE_JS = r"""
() => {
  const el = document.getElementById('__dmh_overlay');
  if (el) el.remove();
}
"""


# ── Daemon ────────────────────────────────────────────────────────────────────

class Daemon:
    def __init__(self):
        self.playwright = None
        self.browser = None

        # user_id → {ctx: BrowserContext, email: str, write_lock: asyncio.Lock}
        # The write_lock serialises storage_state writes from concurrent
        # sessions of the same user — sub-100ms holds, infrequent.
        self.browser_contexts: dict[str, dict] = {}

        # (user_id, session_id) → {page, viewport, last_used_ms}
        # One Playwright Page per chat session. Independent viewport,
        # scroll, and in-flight nav. Inherits cookies/storage from the
        # parent user's BrowserContext.
        self.session_pages: dict[tuple[str, str], dict] = {}

        # Serialise BrowserContext + Page creation across the whole daemon
        # so two simultaneous first-calls from the same user don't double-
        # create. Page actions THEMSELVES are not held under this lock —
        # only the cache-warm step.
        self.create_lock = asyncio.Lock()

        self.last_activity = time.time()
        self._shutting_down = False

    async def start(self):
        self.playwright = await async_playwright().start()
        # --no-sandbox is required because the container runs as root and
        # Chromium's setuid sandbox refuses root.
        # --disable-dev-shm-usage prevents /dev/shm exhaustion on small
        # Docker default tmpfs sizes (Pi defaults to 64M).
        self.browser = await self.playwright.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-gpu",
            ],
        )

    # ── Context / Page resolution ─────────────────────────────────────────────

    async def get_session_page(self, user_id: str, session_id: str, email: str,
                                viewport: dict) -> dict:
        """Resolve (user_id, session_id) → Page, lazily creating both
        layers if needed. Updates viewport if the FE-reported dims
        changed (user switched device between chat opens)."""
        async with self.create_lock:
            # Layer 1: user's BrowserContext.
            ctx_info = self.browser_contexts.get(user_id)
            if ctx_info is None:
                ctx_info = await self._create_browser_context(user_id, email, viewport)
                self.browser_contexts[user_id] = ctx_info

            # Layer 2: session's Page.
            key = (user_id, session_id)
            page_info = self.session_pages.get(key)
            if page_info is None:
                page = await ctx_info["ctx"].new_page()
                page.set_default_timeout(DEFAULT_CMD_TIMEOUT_MS)
                page_info = {"page": page, "viewport": dict(viewport),
                             "last_used_ms": int(time.time() * 1000)}
                self.session_pages[key] = page_info
            else:
                # Page already exists — refresh viewport if it differs.
                cur = page_info["viewport"]
                if cur.get("w") != viewport.get("w") or cur.get("h") != viewport.get("h"):
                    await page_info["page"].set_viewport_size(
                        {"width": int(viewport["w"]), "height": int(viewport["h"])}
                    )
                    page_info["viewport"] = dict(viewport)
                page_info["last_used_ms"] = int(time.time() * 1000)

            return page_info

    async def _create_browser_context(self, user_id: str, email: str,
                                       viewport: dict) -> dict:
        """Create the user's Playwright BrowserContext. The viewport
        passed here is just the initial Page's viewport — the
        BrowserContext-level setting (which Pages inherit on creation)
        uses the same value, but per-page overrides still apply."""
        is_mobile = bool(viewport.get("is_mobile", False))
        kwargs = {
            "user_agent": UA_MOBILE if is_mobile else UA_DESKTOP,
            "viewport": {"width": int(viewport["w"]), "height": int(viewport["h"])},
            "is_mobile": is_mobile,
            "device_scale_factor": 2 if is_mobile else 1,
            "locale": "en-US",
        }
        state_path = self._state_path(email)
        if state_path and os.path.exists(state_path):
            kwargs["storage_state"] = state_path

        ctx = await self.browser.new_context(**kwargs)
        return {"ctx": ctx, "email": email, "write_lock": asyncio.Lock()}

    async def save_state(self, user_id: str):
        """Persist BrowserContext storage_state to disk. Per-user lock
        serialises concurrent writes from multiple sessions of the same
        user. Failures are logged but non-fatal — a missing save just
        means the next call starts from the prior on-disk state."""
        info = self.browser_contexts.get(user_id)
        if not info:
            return
        path = self._state_path(info["email"])
        if not path:
            return
        async with info["write_lock"]:
            try:
                os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
                await info["ctx"].storage_state(path=path)
                os.chmod(path, 0o600)
            except Exception as e:
                sys.stderr.write(f"[daemon] save_state failed user={user_id}: {e}\n")

    def _state_path(self, email: str) -> str | None:
        if not email:
            return None
        return os.path.join(WORK_ROOT, email, ".browser_state.json")

    # ── Command dispatch ──────────────────────────────────────────────────────

    async def execute(self, command: str, args: dict, page_info: dict) -> dict:
        page = page_info["page"]
        timeout = int(args.get("timeout", DEFAULT_CMD_TIMEOUT_MS))
        viewport = page_info["viewport"]
        vw, vh = int(viewport["w"]), int(viewport["h"])

        # ── Navigation ────────────────────────────────────────────────────

        if command == "navigate":
            url = args["url"]
            wait_until = args.get("wait_until", "domcontentloaded")
            resp = await page.goto(url, wait_until=wait_until, timeout=timeout)
            # New DOM means any old stamps are gone with it, but the
            # call is cheap and keeps the invalidation discipline
            # uniform across all state-mutating verbs.
            await self._invalidate_marks(page)
            return {
                "url": page.url,
                "title": await page.title(),
                "status": resp.status if resp else None,
            }

        if command == "back":
            await page.go_back(timeout=timeout)
            await self._invalidate_marks(page)
            return {"url": page.url, "title": await page.title()}

        # ── Observation: enumerate + annotate + screenshot ────────────────

        if command == "observe":
            return await self._cmd_observe(page, vw, vh)

        # ── Indexed action verbs ──────────────────────────────────────────

        if command == "click":
            return await self._cmd_click(page, args)

        if command == "type":
            return await self._cmd_type(page, args)

        if command == "key":
            name = args.get("name")
            if not isinstance(name, str) or not name:
                raise ValueError("key: name required")
            await page.keyboard.press(name)
            await self._invalidate_marks(page)
            return {"pressed": name}

        if command == "scroll_by":
            dx = int(args.get("dx", 0))
            dy = int(args.get("dy", 0))
            await page.mouse.wheel(dx, dy)
            await self._invalidate_marks(page)
            return {"scrolled_by": {"dx": dx, "dy": dy}}

        # ── Content read ──────────────────────────────────────────────────

        if command == "extract_text":
            return await self._cmd_extract_text(page, args, timeout)

        # ── Misc ──────────────────────────────────────────────────────────

        if command == "wait":
            ms = int(args.get("ms", 0))
            ms = max(0, min(ms, 3000))
            await asyncio.sleep(ms / 1000.0)
            # A wait often coincides with a CSS animation completing or
            # an async data-fetch landing — layout may have shifted.
            # Force a re-observe before any indexed verb.
            await self._invalidate_marks(page)
            return {"waited": ms}

        if command == "ping":
            return {"pong": True, "uptime_s": int(time.time() - self.last_activity)}

        raise ValueError(f"unknown command: {command!r}")

    # ── Observation ───────────────────────────────────────────────────────────

    async def _cmd_observe(self, page, vw: int, vh: int) -> dict:
        """Enumerate visible interactives, stamp `data-dmh-idx="N"` on
        each, paint a magenta overlay, screenshot the viewport, strip
        the overlay. Returns the annotated image + the descriptor list
        in one envelope so the Loop never needs a separate screenshot
        verb."""
        # Step 1: enumerate + stamp. Returns a list of descriptor maps
        # already capped and sorted; the same elements are stamped with
        # `data-dmh-idx="N"` for later lookup.
        elements = await page.evaluate(
            _OBSERVE_JS,
            {
                "max_elements": MAX_INTERACTIVES,
                "min_size_px": MIN_INTERACTIVE_SIZE_PX,
                "max_area_frac": MAX_CANDIDATE_AREA_FRAC,
                "indexed_attr": INDEXED_ATTR,
            },
        )

        # Step 2: inject the magenta overlay. Separate from the
        # enumeration so the overlay only exists during the screenshot
        # — page-side code shouldn't see our boxes mid-action.
        await page.evaluate(
            _OVERLAY_INJECT_JS,
            {
                "indexed_attr": INDEXED_ATTR,
                "stroke_px": ANNOTATION_STROKE_PX,
                "label_h_px": ANNOTATION_LABEL_HEIGHT_PX,
            },
        )

        try:
            # Step 3: screenshot the viewport WITH the overlay visible.
            # JPEG q=85 keeps the magenta label text crisp; q=80 was
            # blurring the digits on some font stacks.
            jpg = await page.screenshot(full_page=False, type="jpeg", quality=85)
        finally:
            # Step 4: strip the overlay so it doesn't bleed into the
            # next action's hit-testing or DOM queries.
            await page.evaluate(_OVERLAY_REMOVE_JS)

        import base64
        return {
            "image_b64": base64.b64encode(jpg).decode("ascii"),
            "mime": "image/jpeg",
            "viewport": {"w": vw, "h": vh},
            "url": page.url,
            "title": await page.title(),
            "elements": elements,
        }

    # ── Indexed action verbs ──────────────────────────────────────────────────

    async def _cmd_click(self, page, args: dict) -> dict:
        idx = self._require_index(args)
        handle = await page.query_selector(f'[{INDEXED_ATTR}="{idx}"]')
        if handle is None:
            return self._stale_index(idx)
        button = args.get("button", "left")
        # The Loop dispatches indexed verbs with `timeout =
        # browser_action_timeout_ms` (default 3000) — tighter than the
        # Page-level default_timeout (15 s) so a covered or
        # non-receiving element costs 3 s instead of 15 s.
        timeout = int(args.get("timeout", DEFAULT_ACTION_TIMEOUT_MS))
        tag = await handle.evaluate("el => el.tagName.toLowerCase()")
        try:
            await handle.click(button=button, timeout=timeout)
        except (PWTimeoutError, PWError) as e:
            # Soft fail. Common causes: another element overlays the
            # target (un-dismissed cookie modal), the element is mid-
            # animation, or it just got detached. Loop will re-observe
            # next turn and the model picks a different index.
            await self._invalidate_marks(page)
            return self._action_failed("click", tag, idx, e)

        # The click likely mutated the page (modal dismiss, nav, form
        # submit). Clear all stamps so the next indexed verb either
        # re-observes or returns stale_index.
        await self._invalidate_marks(page)
        return {"clicked": idx, "tag": tag}

    async def _cmd_type(self, page, args: dict) -> dict:
        idx = self._require_index(args)
        handle = await page.query_selector(f'[{INDEXED_ATTR}="{idx}"]')
        if handle is None:
            return self._stale_index(idx)
        text = str(args.get("text", ""))
        submit = bool(args.get("submit", False))
        timeout = int(args.get("timeout", DEFAULT_ACTION_TIMEOUT_MS))

        # Validate the target can actually accept text input BEFORE
        # dispatching keystrokes. Playwright cheerfully dispatches
        # keyboard events to ANY focusable element — including <a>
        # links — and reports success. Without this gate, a model
        # that picks the wrong index gets a misleading "ok" envelope
        # and never learns its target was inappropriate.
        meta = await handle.evaluate(
            "(el) => {\n"
            "  const tag = el.tagName.toLowerCase();\n"
            "  if (tag === 'textarea') return {tag, typeable: true};\n"
            "  if (tag === 'input') {\n"
            "    const t = (el.getAttribute('type') || 'text').toLowerCase();\n"
            "    const blocked = ['hidden','button','submit','reset','image',"
            "'file','checkbox','radio','color','range'];\n"
            "    return {tag, type: t, typeable: !blocked.includes(t)};\n"
            "  }\n"
            "  return {tag, typeable: !!el.isContentEditable};\n"
            "}"
        )
        tag = meta.get("tag")
        if not meta.get("typeable"):
            type_hint = f" type=\"{meta['type']}\"" if meta.get("type") else ""
            return {
                "error": "not_typeable",
                "reason": (
                    f"<{tag}{type_hint}> at idx={idx} cannot receive text input — "
                    f"pick an <input> / <textarea> / contenteditable element"
                ),
            }
        # Focus the input, clear, then type real keystrokes. The
        # clear-via-keyboard pattern handles inputs and textareas; for
        # contenteditable elements `.fill("")` works but `keyboard.press`
        # is universal. `keyboard.type` (not `fill`) fires per-keystroke
        # events that autocomplete components depend on.
        try:
            # `ElementHandle.focus()` is intentionally argless in
            # Playwright Python — it dispatches a focus event directly
            # without actionability checks. The locator API has
            # `Locator.focus(timeout=...)`, but on an already-resolved
            # ElementHandle there's nothing to wait for. Click's
            # timeout below still bounds the keyboard-type phase via
            # the page's default_timeout.
            await handle.focus()
            await page.keyboard.press("ControlOrMeta+a")
            await page.keyboard.press("Delete")
            await page.keyboard.type(text)
            if submit:
                await page.keyboard.press("Enter")
        except (PWTimeoutError, PWError) as e:
            await self._invalidate_marks(page)
            return self._action_failed("type", tag, idx, e)
        await self._invalidate_marks(page)
        return {"typed": idx, "submitted": submit}

    async def _cmd_extract_text(self, page, args: dict, timeout: int) -> dict:
        # Two modes: `{}` or `{"index": null}` → whole body. `{"index": N}` →
        # the indexed element's innerText.
        if "index" in args and args["index"] is not None:
            idx = self._require_index(args)
            handle = await page.query_selector(f'[{INDEXED_ATTR}="{idx}"]')
            if handle is None:
                return self._stale_index(idx)
            text = await handle.inner_text()
            matches = 1
        else:
            locator = page.locator("body")
            # state="attached" — read text whether or not the element
            # is currently rendered visible. The default "visible"
            # waits for layout, which times out on bodies whose
            # children are all absolute-positioned (body has zero
            # intrinsic height) and on pages whose root is
            # display:none in a stylesheet.
            await locator.first.wait_for(state="attached", timeout=timeout)
            texts = await locator.all_inner_texts()
            text = "\n".join(t.strip() for t in texts if t.strip())
            matches = len(texts)
        cap = int(args.get("max_chars", 20_000))
        if len(text) > cap:
            text = text[:cap] + f"\n\n[…truncated at {cap} chars]"
        return {"text": text, "url": page.url, "matches": matches}

    # ── Mark cache helpers ────────────────────────────────────────────────────

    async def _invalidate_marks(self, page) -> None:
        """Remove every `data-dmh-idx` stamp on the current Page. Called
        after every state-mutating verb so a subsequent indexed verb
        without an intervening `observe` returns `stale_index` instead
        of silently acting on a stamped element whose visual state has
        shifted."""
        try:
            await page.evaluate(
                "(attr) => { for (const el of "
                "document.querySelectorAll('['+attr+']')) "
                "el.removeAttribute(attr); }",
                INDEXED_ATTR,
            )
        except Exception:
            # Page navigated mid-call or context destroyed — the old
            # DOM (and its stamps) is gone either way, so swallowing
            # the error preserves the invariant.
            pass

    def _require_index(self, args: dict) -> int:
        idx = args.get("index")
        if isinstance(idx, bool) or not isinstance(idx, int):
            raise ValueError("index: positive integer required")
        if idx < 1:
            raise ValueError(f"index: must be >= 1, got {idx}")
        return idx

    def _stale_index(self, idx: int) -> dict:
        """Soft-error envelope. The daemon_client.ex `interpret/1`
        clause picks this up as `{:error, {:daemon_error,
        %{type: "stale_index", ...}}}` so the Loop can fold it into the
        RECENT ACTIONS line without halting."""
        return {
            "error": "stale_index",
            "reason": (
                f"no element {idx} in current observation — page mutated "
                f"or this verb came before `observe`; re-observe and try again"
            ),
        }

    def _action_failed(self, verb: str, tag: str, idx: int, exc: Exception) -> dict:
        """Soft-error envelope for click / type that Playwright refused.
        Typical causes: a higher-z-index overlay (un-dismissed cookie
        modal) intercepts the click, the element is mid-animation, or
        it got detached. Trim the Playwright error to its first line —
        the full message includes a Call log block useful only in
        interactive debugging and noisy in the agent's RECENT ACTIONS
        prompt."""
        first_line = str(exc).split("\n", 1)[0].strip()
        return {
            "error": "action_failed",
            "reason": f"{verb} on {tag}[idx={idx}] failed: {first_line}",
        }

    # ── Connection handling ───────────────────────────────────────────────────

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        try:
            line = await reader.readline()
            if not line:
                return
            try:
                req = json.loads(line)
            except json.JSONDecodeError as e:
                self._reply(writer, {"id": None, "ok": False,
                                      "error": f"malformed JSON: {e}",
                                      "type": "JSONDecodeError"})
                return

            self.last_activity = time.time()
            corr_id = req.get("id")
            user_id = req.get("user_id")
            session_id = req.get("session_id") or ""
            email = req.get("email") or ""
            command = req.get("command")
            args = req.get("args") or {}
            viewport = req.get("viewport") or FALLBACK_VIEWPORT

            if not isinstance(user_id, str) or not user_id:
                self._reply(writer, {"id": corr_id, "ok": False,
                                      "error": "user_id required",
                                      "type": "ValueError"})
                return
            if not isinstance(session_id, str) or not session_id:
                # ping is the one command we allow without a session
                if command != "ping":
                    self._reply(writer, {"id": corr_id, "ok": False,
                                          "error": "session_id required",
                                          "type": "ValueError"})
                    return
            if not isinstance(command, str) or not command:
                self._reply(writer, {"id": corr_id, "ok": False,
                                      "error": "command required",
                                      "type": "ValueError"})
                return

            try:
                if command == "ping" and not session_id:
                    result = await self.execute(command, args, {"page": None,
                                                                  "viewport": viewport})
                else:
                    page_info = await self.get_session_page(user_id, session_id,
                                                             email, viewport)
                    result = await self.execute(command, args, page_info)
                    # Persist state after every successful command —
                    # cheaper than only-on-mutation detection and more
                    # crash-resistant. Idempotent for read-only commands
                    # (just rewrites the same JSON).
                    await self.save_state(user_id)
                self._reply(writer, {"id": corr_id, "ok": True, "result": result})

            except PWTimeoutError as e:
                self._reply(writer, {"id": corr_id, "ok": False,
                                      "error": str(e),
                                      "type": "TimeoutError"})
            except PWError as e:
                self._reply(writer, {"id": corr_id, "ok": False,
                                      "error": str(e),
                                      "type": "PlaywrightError"})
            except Exception as e:
                tb = traceback.format_exc(limit=3)
                sys.stderr.write(f"[daemon] handler error: {tb}\n")
                self._reply(writer, {"id": corr_id, "ok": False,
                                      "error": str(e),
                                      "type": type(e).__name__})

        finally:
            try:
                # asyncio.StreamWriter.write() is non-blocking; bytes sit
                # in the transport buffer until the event loop flushes
                # them. close() schedules an EOF without waiting for that
                # flush, so for any reply larger than the buffer the EOF
                # races the tail bytes — peer reads a truncated JSON line
                # and JSONDecodeError fires on the master side. drain()
                # blocks until the buffer drops below the high-water mark;
                # on a one-reply-per-connection protocol that means
                # everything is on the wire.
                await writer.drain()
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    def _reply(self, writer: asyncio.StreamWriter, payload: dict):
        try:
            writer.write((json.dumps(payload) + "\n").encode("utf-8"))
        except Exception as e:
            sys.stderr.write(f"[daemon] reply write failed: {e}\n")

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    async def idle_watchdog(self):
        while not self._shutting_down:
            await asyncio.sleep(WATCHDOG_INTERVAL_S)
            if time.time() - self.last_activity > IDLE_SHUTDOWN_S:
                sys.stderr.write(
                    f"[daemon] idle {IDLE_SHUTDOWN_S}s, shutting down to free Chromium memory\n"
                )
                await self.shutdown()
                return

    async def shutdown(self):
        if self._shutting_down:
            return
        self._shutting_down = True

        # Close per-session Pages first.
        for key in list(self.session_pages.keys()):
            try:
                await self.session_pages[key]["page"].close()
            except Exception:
                pass

        # Then per-user BrowserContexts (flushing storage_state on the
        # way out so unsaved cookies persist).
        for user_id in list(self.browser_contexts.keys()):
            try:
                await self.save_state(user_id)
                await self.browser_contexts[user_id]["ctx"].close()
            except Exception:
                pass

        try:
            await self.browser.close()
        except Exception:
            pass
        try:
            await self.playwright.stop()
        except Exception:
            pass

        # Loop.stop schedules termination; sys.exit ensures exit code 0
        # so start.sh's supervisor relaunches cleanly on next demand.
        loop = asyncio.get_running_loop()
        loop.call_soon(loop.stop)

    async def serve(self):
        await self.start()

        os.makedirs(os.path.dirname(SOCK_PATH), mode=0o775, exist_ok=True)
        if os.path.exists(SOCK_PATH):
            os.remove(SOCK_PATH)
        server = await asyncio.start_unix_server(self.handle, path=SOCK_PATH)
        # 0666 lets the master container connect via the bind-mount;
        # the container fence (sandbox UID isolation) keeps this safe.
        os.chmod(SOCK_PATH, 0o666)
        sys.stderr.write(
            f"[daemon] listening on {SOCK_PATH} (idle_shutdown={IDLE_SHUTDOWN_S}s)\n"
        )

        watchdog = asyncio.create_task(self.idle_watchdog())

        # Graceful SIGTERM — start.sh might restart us on container stop.
        def _sigterm(*_):
            asyncio.create_task(self.shutdown())
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, _sigterm)

        async with server:
            try:
                await server.serve_forever()
            except asyncio.CancelledError:
                pass
        watchdog.cancel()


def main():
    asyncio.run(Daemon().serve())


if __name__ == "__main__":
    main()
