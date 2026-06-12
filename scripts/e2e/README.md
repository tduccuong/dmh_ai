# Browser e2e

End-to-end smoke tests that drive the real DMH-AI web UI in headless
Chromium over the DevTools Protocol — clicking buttons and reading
rendered text the way a user would, then asserting on the result.

These run against a **running stage instance**, not the unit-test
sandbox. They complement (do not replace) the ExUnit suite under
`code/backend/test/`.

## Prerequisites

- A running stage: `./scripts/build.sh --stage && ./dist/install.sh --stage`
- `chromium` on PATH (the system browser binary)
- `pip install websocket-client`

## Run

```bash
python3 scripts/e2e/confidant_memory_e2e.py
```

Exit code `0` = all assertions passed, `1` = a failure (each check
prints `PASS`/`FAIL` with detail). Screenshots land in
`scripts/e2e/shots/` (gitignored).

Config via env: `DMHAI_E2E_URL` (default `http://127.0.0.1:8080`),
`DMHAI_E2E_CONTAINER` (default `dmh_ai-master`).

## What `confidant_memory_e2e.py` covers

Creates a throwaway admin user (via the container `rpc` console),
then through the UI:

1. logs in,
2. states three facts in chat (cats / half-marathon / job),
3. saves a memo with `/memo`,
4. asks "what is my gym locker code?" — answer must come from the
   `<user_memos>` block (kb_query),
5. asks "what do you remember about me?" — answer must surface the
   extracted `<user_facts>` (kb_query),
6. cross-checks `facts.db` / `memos.db` row counts (kb_index),
7. opens the unified Settings modal and asserts the tab set + that the
   Assistant model picker is gone.

The user and all its facts/memos are deleted on exit.

## Files

- `cdp.py` — minimal CDP driver (launch/teardown chromium, navigate,
  evaluate JS, wait-for, screenshot). Reusable by other flows.
- `confidant_memory_e2e.py` — the confidant-memory flow above.
