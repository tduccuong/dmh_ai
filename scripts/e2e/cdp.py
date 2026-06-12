"""Minimal Chrome DevTools Protocol driver over websocket-client.

Drives the real DMH-AI web UI the same way a human would — typing into
inputs, clicking buttons, reading rendered text — and captures
screenshots. No selenium / playwright / node needed; only the system
`chromium` binary plus the `websocket-client` Python package.
"""
import os
import json
import time
import base64
import signal
import tempfile
import subprocess
import urllib.request

import websocket

CDP = "http://127.0.0.1:9222"
SHOTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shots")


def _http(path):
    return json.load(urllib.request.urlopen(CDP + path, timeout=5))


def launch():
    """Start headless chromium as a child process; wait for CDP. Returns Popen.

    Uses a throwaway profile dir so runs don't interfere. The
    `--remote-allow-origins=*` flag is required or chromium rejects the
    websocket handshake with HTTP 403.
    """
    subprocess.run(["pkill", "-f", "remote-debugging-port=9222"],
                   stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    profile = tempfile.mkdtemp(prefix="dmhai-e2e-chrome-")
    proc = subprocess.Popen([
        "chromium", "--headless=new", "--no-sandbox", "--disable-gpu",
        "--disable-dev-shm-usage", "--remote-debugging-port=9222",
        "--remote-allow-origins=*", "--user-data-dir=" + profile,
        "--window-size=1280,900", "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(40):
        try:
            urllib.request.urlopen(CDP + "/json/version", timeout=2)
            return proc
        except Exception:
            time.sleep(0.5)
    raise RuntimeError("CDP did not come up on :9222")


def shutdown(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        try:
            proc.terminate()
        except Exception:
            pass


def _page_ws():
    for t in _http("/json/list"):
        if t.get("type") == "page":
            return t["webSocketDebuggerUrl"]
    raise RuntimeError("no page target")


class Page:
    def __init__(self):
        os.makedirs(SHOTS, exist_ok=True)
        self.ws = websocket.create_connection(_page_ws(), max_size=None, timeout=60)
        self._id = 0
        self.cmd("Page.enable")
        self.cmd("Runtime.enable")
        self.cmd("DOM.enable")

    def cmd(self, method, **params):
        self._id += 1
        mid = self._id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})

    def navigate(self, url):
        self.cmd("Page.navigate", url=url)
        self.wait_ready()

    def wait_ready(self, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            if self.eval("document.readyState") == "complete":
                return
            time.sleep(0.2)
        raise RuntimeError("page not ready")

    def eval(self, expr, await_promise=False):
        r = self.cmd("Runtime.evaluate", expression=expr, returnByValue=True,
                     awaitPromise=await_promise, userGesture=True)
        if r.get("exceptionDetails"):
            raise RuntimeError("JS exception: " + json.dumps(r["exceptionDetails"])[:400])
        return r.get("result", {}).get("value")

    def wait_for(self, js_bool_expr, timeout=20, poll=0.3):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if self.eval(js_bool_expr):
                    return True
            except Exception:
                pass
            time.sleep(poll)
        return False

    def shot(self, name):
        r = self.cmd("Page.captureScreenshot", format="png")
        path = os.path.join(SHOTS, f"{name}.png")
        with open(path, "wb") as f:
            f.write(base64.b64decode(r["data"]))
        return path

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass
