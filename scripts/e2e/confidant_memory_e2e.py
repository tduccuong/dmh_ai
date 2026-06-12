#!/usr/bin/env python3
"""Browser e2e: confidant memory (facts + memos) through the real UI.

Acts as a human against a running stage instance: logs in, states a few
facts, saves a /memo, then asks questions whose answers can only come
from kb_query retrieval (the <user_facts> / <user_memos> blocks). Also
screenshots the unified tabbed Settings modal.

Proves end to end:
  * kb_index   — FactExtractor writes facts.db; /memo writes memos.db
  * kb_query   — Kb.Query.blocks injects <user_facts>/<user_memos>, and
                 the model answers from them (locker code, owned pets…)

Prereqs: a running stage (./dist/install.sh --stage), the `chromium`
binary, and `pip install websocket-client`. Creates a throwaway admin
user via the container's `rpc` console and deletes it on exit.

Usage:  python3 scripts/e2e/confidant_memory_e2e.py
Env:    DMHAI_E2E_URL (default http://127.0.0.1:8080)
        DMHAI_E2E_CONTAINER (default dmh_ai-master)
Exit:   0 = all assertions passed, 1 = a failure (details on stdout).
"""
import os
import sys
import time
import subprocess

from cdp import Page, launch, shutdown

URL = os.environ.get("DMHAI_E2E_URL", "http://127.0.0.1:8080")
CONTAINER = os.environ.get("DMHAI_E2E_CONTAINER", "dmh_ai-master")
UID = "e2e_smoke"
EMAIL = "e2e_smoke@e2e.local"
PASSWORD = "E2ePass123"

FACTS = [
    "I have two cats named Mochi and Pixel.",
    "I'm training for a half marathon this October.",
    "I work as a pediatric nurse in Lyon.",
]
MEMO = "/memo My gym locker code is 4417."


def rpc(code):
    """Run Elixir in the running container's console. Returns stdout."""
    out = subprocess.run(
        ["docker", "exec", CONTAINER, "/app/bin/dmh_ai", "rpc", code],
        capture_output=True, text=True, timeout=60,
    )
    return out.stdout + out.stderr


def create_user():
    code = (
        'uid="%s"; org=DmhAi.Constants.default_org_id(); '
        'DmhAi.Repo.query!("DELETE FROM sessions WHERE user_id=?",[uid]); '
        'DmhAi.Repo.query!("DELETE FROM auth_tokens WHERE user_id=?",[uid]); '
        'DmhAi.Repo.query!("DELETE FROM users WHERE id=?",[uid]); '
        'DmhAi.FactsRepo.query!("DELETE FROM facts_sources WHERE user_id=?",[uid]); '
        'DmhAi.FactsRepo.query!("DELETE FROM facts_watermark WHERE user_id=?",[uid]); '
        'DmhAi.MemosRepo.query!("DELETE FROM memos_sources WHERE user_id=?",[uid]); '
        'h=DmhAi.AuthPlug.hash_password("%s"); now=System.os_time(:millisecond); '
        'DmhAi.Repo.query!("INSERT INTO users (id,email,name,password_hash,role,org_id,org_role,created_at) '
        'VALUES (?,?,?,?,?,?,?,?)",[uid,"%s","E2E Smoke",h,"admin",org,"admin",now]); '
        'IO.puts("USER_OK")'
    ) % (UID, PASSWORD, EMAIL)
    return "USER_OK" in rpc(code)


def delete_user():
    code = (
        'uid="%s"; '
        'DmhAi.Repo.query!("DELETE FROM sessions WHERE user_id=?",[uid]); '
        'DmhAi.Repo.query!("DELETE FROM auth_tokens WHERE user_id=?",[uid]); '
        'DmhAi.Repo.query!("DELETE FROM users WHERE id=?",[uid]); '
        'DmhAi.FactsRepo.query!("DELETE FROM facts_sources WHERE user_id=?",[uid]); '
        'DmhAi.FactsRepo.query!("DELETE FROM facts_watermark WHERE user_id=?",[uid]); '
        'DmhAi.MemosRepo.query!("DELETE FROM memos_sources WHERE user_id=?",[uid]); '
        'IO.puts("CLEAN_OK")'
    ) % UID
    rpc(code)


def store_counts():
    code = (
        'uid="%s"; '
        'f=DmhAi.FactsRepo.query!("SELECT COUNT(*) FROM facts_sources WHERE user_id=?",[uid]).rows|>hd|>hd; '
        'm=DmhAi.MemosRepo.query!("SELECT COUNT(*) FROM memos_sources WHERE user_id=?",[uid]).rows|>hd|>hd; '
        'IO.puts("COUNTS f=#{f} m=#{m}")'
    ) % UID
    out = rpc(code)
    for line in out.splitlines():
        if line.startswith("COUNTS "):
            parts = dict(p.split("=") for p in line.split()[1:])
            return int(parts["f"]), int(parts["m"])
    return 0, 0


# ── browser helpers ──────────────────────────────────────────────────────

def login(p):
    p.navigate(URL + "/")
    p.wait_for("!!document.getElementById('login-password')", timeout=20)
    p.eval("""(function(){
      var e=document.getElementById('login-email'), pw=document.getElementById('login-password');
      e.value=%r; e.dispatchEvent(new Event('input',{bubbles:true}));
      pw.value=%r; pw.dispatchEvent(new Event('input',{bubbles:true}));
    })()""" % (EMAIL, PASSWORD))
    p.eval("Array.from(document.querySelectorAll('button')).find(x=>/sign in/i.test(x.textContent)).click()")
    return p.wait_for("!!document.getElementById('message-input')", timeout=20)


def _acount(p):
    return p.eval("document.querySelectorAll('.message.assistant').length")


def _last_assistant(p):
    return p.eval("(function(){var n=document.querySelectorAll('.message.assistant');"
                  "if(!n.length)return '';var b=n[n.length-1].querySelector('.msg-body');"
                  "return b?b.innerText.trim():''})()") or ""


def send(p, text):
    prev = _acount(p)
    p.eval("(function(t){var i=document.getElementById('message-input');i.value=t;"
           "i.dispatchEvent(new Event('input',{bubbles:true}));"
           "document.getElementById('send-btn').click();})(%r)" % text)
    return prev


def _streaming(p):
    return bool(p.eval("typeof UIManager !== 'undefined' && !!UIManager.isStreaming"))


def wait_reply(p, prev, timeout=90):
    """Wait until the turn fully completes — a new assistant bubble exists,
    streaming has stopped, and its text is non-empty.

    Gating on `isStreaming == false` is essential: returning mid-stream
    makes the next send take the mid-chain path (no fresh placeholder),
    which strands the conversation. An LLM turn flips `isStreaming` true
    then false; a `/memo` command renders its ack instantly without
    streaming — the leading grace covers both.
    """
    time.sleep(1.5)  # let an LLM turn flip isStreaming true before we poll
    end = time.time() + timeout
    while time.time() < end:
        if not _streaming(p) and _acount(p) > prev:
            t = _last_assistant(p)
            if t:
                return t
        time.sleep(1.0)
    return _last_assistant(p)


def main():
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + ((" — " + detail) if detail else ""))

    if not create_user():
        print("FAIL could not create test user (is the stage running?)")
        return 1

    proc = launch()
    try:
        p = Page()
        check("login", login(p))
        p.shot("01_login_done")

        for m in FACTS:
            prev = send(p, m)
            wait_reply(p, prev)
        p.shot("02_facts_sent")

        prev = send(p, MEMO)
        ack = wait_reply(p, prev, timeout=30)
        check("memo_ack", "saved" in ack.lower() or "lưu" in ack.lower() or "gespeichert" in ack.lower(), ack[:50])

        time.sleep(12)  # let the background fact extractor run

        prev = send(p, "What is my gym locker code?")
        recall = wait_reply(p, prev)
        check("memo_recall_kb_query", "4417" in recall, recall[:90])
        p.shot("03_memo_recall")

        prev = send(p, "What do you remember about me so far?")
        facts = wait_reply(p, prev).lower()
        hits = sum(x in facts for x in ["mochi", "cat", "marathon", "nurse", "lyon"])
        check("fact_recall_kb_query", hits >= 2, f"{hits}/5 fact signals present")
        p.shot("04_fact_recall")

        fcount, mcount = store_counts()
        check("kb_index_facts_db", fcount >= 3, f"facts.db rows={fcount}")
        check("kb_index_memos_db", mcount >= 1, f"memos.db rows={mcount}")

        # Unified settings modal — tab presence + screenshot.
        p.eval("document.getElementById('user-menu-btn').click()")
        time.sleep(0.4)
        p.eval("document.getElementById('user-settings-btn').click()")
        time.sleep(0.8)
        tabs = p.eval("Array.from(document.querySelectorAll('.settings-tab')).map(t=>t.getAttribute('data-page')).join(',')")
        check("settings_tabs", tabs == "page-model,page-ai-models,page-conversation,page-read-out-loud", tabs or "(none)")
        no_assistant = p.eval("!document.getElementById('assistant-model-search')")
        check("no_assistant_picker", no_assistant)
        p.shot("05_settings")
    finally:
        shutdown(proc)
        delete_user()

    failed = [n for n, ok, _ in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
