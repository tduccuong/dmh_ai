#!/usr/bin/env python3
# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com
"""
DMH-AI browser daemon — Phase 2 of #215.

One long-lived Playwright process holding ONE Chromium instance for
the whole deployment, with one BrowserContext per `user_id`. Pi-aware
resource model: lazy context creation, idle-shutdown reclaims memory.

Listens on a Unix socket at /var/run/dmh-browser/daemon.sock with
newline-JSON request/response framing. One connection per request;
no in-flight pipelining to keep the protocol trivial.

See arch_wiki/dmh_ai/architecture.md §"Browser tools" for the
command surface, the IPC protocol, and v0 limitations.
"""

import asyncio
import json
import os
import signal
import sys
import time
import traceback

from playwright.async_api import async_playwright, Error as PWError, TimeoutError as PWTimeoutError

# ── Tuning ────────────────────────────────────────────────────────────────────

SOCK_PATH = os.environ.get("BROWSER_SOCK_PATH", "/var/run/dmh-browser/daemon.sock")

# Idle shutdown: kill Chromium + exit if no requests for this long.
# start.sh's supervisor relaunches us on next call. Pi-class hosts
# reclaim ~150–250 MB of RSS this way.
IDLE_SHUTDOWN_S = int(os.environ.get("BROWSER_IDLE_SHUTDOWN_S", "1800"))

# Workspace root, bind-mounted into the container at /work. Per-user
# Playwright storage_state lives at /work/<email>/.browser_state.json.
WORK_ROOT = "/work"

# Per-command default timeout (ms). Overridable per-call via args.timeout.
DEFAULT_CMD_TIMEOUT_MS = 15_000

# How often the idle watchdog wakes up to check the timer.
WATCHDOG_INTERVAL_S = 30


# ── Daemon ────────────────────────────────────────────────────────────────────

class Daemon:
    def __init__(self):
        self.playwright = None
        self.browser = None
        # user_id -> {"context": BrowserContext, "page": Page, "email": str}
        self.contexts: dict[str, dict] = {}
        self.last_activity = time.time()
        # v0 serialises all turns globally — single asyncio lock.
        # Promote to per-user when browserConcurrencyPerUser > 1.
        self.global_lock = asyncio.Lock()
        self._shutting_down = False

    async def start(self):
        self.playwright = await async_playwright().start()
        # Default flags. --no-sandbox is required because the container
        # runs as root and Chromium's setuid sandbox refuses root.
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

    async def get_context(self, user_id: str, email: str):
        """Lazy-create or return the cached BrowserContext for `user_id`.

        On first creation, attempts to load Playwright `storage_state`
        from `/work/<email>/.browser_state.json` so cookies persist
        across calls.
        """
        info = self.contexts.get(user_id)
        if info is not None:
            return info

        kwargs = {
            "user_agent": (
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            ),
            "viewport": {"width": 1280, "height": 800},
            "locale": "en-US",
        }
        state_path = self._state_path(email)
        if state_path and os.path.exists(state_path):
            try:
                kwargs["storage_state"] = state_path
            except Exception:
                # Corrupt state file shouldn't block a fresh context.
                pass

        ctx = await self.browser.new_context(**kwargs)
        page = await ctx.new_page()
        # Default timeout — can be overridden per-call.
        page.set_default_timeout(DEFAULT_CMD_TIMEOUT_MS)
        info = {"context": ctx, "page": page, "email": email}
        self.contexts[user_id] = info
        return info

    async def save_state(self, user_id: str):
        """Persist BrowserContext storage_state to disk so the next
        invocation reuses cookies. Called after every successful turn
        that may have mutated state. Failures here are logged but
        non-fatal — a missing save just means the next call starts
        fresh."""
        info = self.contexts.get(user_id)
        if not info:
            return
        path = self._state_path(info["email"])
        if not path:
            return
        try:
            os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
            await info["context"].storage_state(path=path)
            os.chmod(path, 0o600)
        except Exception as e:
            sys.stderr.write(f"[daemon] save_state failed user={user_id}: {e}\n")

    def _state_path(self, email: str) -> str | None:
        if not email:
            return None
        return os.path.join(WORK_ROOT, email, ".browser_state.json")

    # ── Command dispatch ──────────────────────────────────────────────────────

    async def execute(self, command: str, args: dict, page) -> dict:
        timeout = int(args.get("timeout", DEFAULT_CMD_TIMEOUT_MS))

        if command == "navigate":
            url = args["url"]
            wait_until = args.get("wait_until", "load")
            resp = await page.goto(url, wait_until=wait_until, timeout=timeout)
            return {
                "url": page.url,
                "title": await page.title(),
                "status": resp.status if resp else None,
            }

        if command == "scroll":
            if args.get("to_selector"):
                sel = args["to_selector"]
                await page.locator(sel).scroll_into_view_if_needed(timeout=timeout)
                return {"scrolled_to": sel}
            amount = int(args.get("amount", 500))
            await page.evaluate(f"window.scrollBy(0, {amount})")
            return {"scrolled_by": amount}

        if command == "wait_for_selector":
            sel = args["selector"]
            await page.locator(sel).wait_for(timeout=timeout, state=args.get("state", "visible"))
            return {"appeared": sel}

        if command == "wait_for_load":
            state = args.get("state", "load")
            await page.wait_for_load_state(state, timeout=timeout)
            return {"loaded": state}

        if command == "extract_text":
            sel = args.get("selector", "body")
            text = await page.locator(sel).first.inner_text(timeout=timeout)
            # Cap aggressive output sizes — runtime caps the trace log
            # again, but trimming here saves IPC traffic on Pi.
            cap = int(args.get("max_chars", 20_000))
            if len(text) > cap:
                text = text[:cap] + f"\n\n[…truncated at {cap} chars]"
            return {"text": text, "url": page.url}

        if command == "accessibility_snapshot":
            tree = await page.accessibility.snapshot(interesting_only=True)
            return {"tree": tree, "url": page.url}

        if command == "screenshot":
            path = args["path"]
            os.makedirs(os.path.dirname(path), exist_ok=True)
            await page.screenshot(
                path=path,
                full_page=bool(args.get("full_page", False)),
                timeout=timeout,
            )
            return {"path": path}

        if command == "click":
            sel = args["selector"]
            await page.locator(sel).click(timeout=timeout)
            return {"clicked": sel}

        if command == "type":
            sel = args["selector"]
            await page.locator(sel).type(args["text"], delay=int(args.get("delay", 50)), timeout=timeout)
            return {"typed": True}

        if command == "fill":
            sel = args["selector"]
            await page.locator(sel).fill(args["value"], timeout=timeout)
            return {"filled": True}

        if command == "select":
            sel = args["selector"]
            await page.locator(sel).select_option(args["value"], timeout=timeout)
            return {"selected": True}

        if command == "keyboard":
            await page.keyboard.press(args["key"])
            return {"pressed": args["key"]}

        if command == "ping":
            return {"pong": True, "uptime_s": int(time.time() - self.last_activity)}

        raise ValueError(f"unknown command: {command!r}")

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
            email = req.get("email") or ""
            command = req.get("command")
            args = req.get("args") or {}

            if not isinstance(user_id, str) or not user_id:
                self._reply(writer, {"id": corr_id, "ok": False,
                                      "error": "user_id required",
                                      "type": "ValueError"})
                return
            if not isinstance(command, str) or not command:
                self._reply(writer, {"id": corr_id, "ok": False,
                                      "error": "command required",
                                      "type": "ValueError"})
                return

            try:
                async with self.global_lock:
                    info = await self.get_context(user_id, email)
                    result = await self.execute(command, args, info["page"])
                    # Persist state after every successful command —
                    # cheaper than only-on-mutation detection and
                    # more crash-resistant. Idempotent for read-only
                    # commands (just rewrites the same JSON).
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
        for user_id in list(self.contexts.keys()):
            try:
                await self.save_state(user_id)
                await self.contexts[user_id]["context"].close()
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
        # 0660 lets the master service (group) connect via bind-mount;
        # adjust at deploy-time if the host UID/GID differs.
        os.chmod(SOCK_PATH, 0o666)
        sys.stderr.write(f"[daemon] listening on {SOCK_PATH} (idle_shutdown={IDLE_SHUTDOWN_S}s)\n")

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
