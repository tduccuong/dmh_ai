# Layer W — Workflow Compiler + Executor UAT runbook

This is the manual smoke-test for the **end-to-end** workflow
loop after Phase B (deterministic executor) lands:

```
chat prompt → compiler emits IR → user arms → manual invoke
            → executor walks IR → run completes → audit log
```

Run this against the stage instance at `http://127.0.0.1:8080/`
after a `./scripts/build.sh --stage && ./dist/install.sh --stage`
cycle. None of the scenarios below need real vendor credentials
— they're all internal-primitive only so the executor can be
exercised without OAuth setup.

## Pre-flight

1. Stage is up: `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/` → `200`.
2. Log in as the seeded admin (`admin@dmhai.local` / `123456`).
3. Open a fresh Assistant-mode session.

## Scenario A — Output-only "smoke test" workflow

Quickest path to verify the compiler save + executor run loop is
alive. No vendor creds; no LLM in the run loop.

### A.1 — Save

Type into chat:

> Build me a smoke-test workflow that immediately completes and
> emits `ok: true`. Name it `smoke_test`.

The compiler should respond with a link of the form
`[Smoke test · v0](/workflows/smoke_test/0)`. **Click it** —
the viewer modal opens with one Output node carrying
`emit: { ok: true }`.

### A.2 — Arm

In chat:

> arm smoke_test v0

Backend echoes "armed v0". `workflows.active_version = 0`.

### A.3 — Invoke

In chat:

> run smoke_test

OR the LLM may emit `invoke_workflow(name: "smoke_test",
inputs: {})` directly. Expected reply embeds:

```
{
  "executor_status": "completed",
  "run_id":          "<uuid>",
  "version":         0
}
```

### A.4 — Verify

Open SQLite against the stage DB and inspect:

```sql
SELECT id, status, bindings FROM workflow_run_state
  ORDER BY started_at DESC LIMIT 1;
```

Expected: one row with `status = 'completed'` and a `bindings`
JSON whose `emits` map carries the output node's emit.

## Scenario B — Compose-only workflow (synthetic step)

Exercises the `llm.compose` synthetic — the executor's
LLM-as-renderer path. Still no vendor creds.

### B.1 — Save

> Build me a workflow `greet_user` that takes a `name` trigger
> input and emits `text: "Hello, <name>!"`. Use the llm.compose
> synthetic to render the greeting.

The compiler should emit two nodes: a `llm.compose` step with
template `"Hello, {{name}}!"` and context `{name: "{{T.name}}"}`,
followed by an output node binding `text: "{{1.body}}"`.

### B.2 — Arm + Invoke

> arm greet_user v0
> run greet_user with inputs `{ "name": "world" }`

Expected: `status = "completed"`, output emit
`text: "Hello, world!"`.

## Scenario C — Branch routing

The branch node + predicate language.

### C.1 — Save

> Build me a workflow `route_demo` that takes a `flag` input
> ("go" or "stop"). When flag is "go" emit `route: matched`;
> otherwise emit `route: fallback`. Name the workflow exactly
> `route_demo`.

The compiler should produce: branch node with one case
`{{T.flag}} == "go"` → output `matched`, else → output
`fallback`.

### C.2 — Run both paths

> run route_demo with inputs `{ "flag": "go" }`     → emit `route: matched`
> run route_demo with inputs `{ "flag": "stop" }`   → emit `route: fallback`

## Scenario D — Permission denial at compile time

This one MUST fail at save — confirms the permission gate fires.
Requires a second (non-admin) user.

### D.1 — Seed a non-admin

```sql
INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at)
VALUES ('u_member', 'member@test.local', 'Member', 'x', 'user', 'default', 'member', strftime('%s', 'now'));
```

Log in as `member@test.local`.

### D.2 — Attempt cross-user creds workflow

Pick `@admin` from the mention picker. Type:

> Build me a workflow that uses @admin's Google Workspace Gmail
> to send a daily digest. Name it `bad_cross_user`.

The compiler should attempt save and the
`upsert_workflow` tool should refuse with a
`permission_denied` error citing:

- `action = :act_as_creds`
- `target = creds:google_workspace:<admin_uid>`
- `reason = :not_admin`
- A remediation list with "use your own credentials" etc.

The chat reply renders the denial as a request to the user
(member) to pick a remediation. No `workflow_versions` row
is written.

## Scenario E — @-mention sidecar resolution

Verifies the FE picker + BE sidecar plumbing.

### E.1 — Trigger the picker

Type `@` in the chat textarea. A dropdown should appear listing
same-org members (admin, plus any others you seeded for
scenario D). Arrow keys / Tab / Enter select; Esc closes.

### E.2 — Send a message with a mention

Pick `@admin` from the picker, finish with any text:

> @admin can you check the inbox digest?

POST the message. In the stage's database:

```sql
SELECT content FROM session_messages
  WHERE session_id = '<your_session_id>'
  ORDER BY ts DESC LIMIT 1;
```

The stored content should be prefixed with:

```
<mentions>
  @admin => <admin_user_id>
</mentions>
@admin can you check the inbox digest?
```

This is the LLM-visible form. The compiler reads the `<mentions>`
block and uses the literal `user_id` for any subsequent IR
references.

## Pass / fail criteria

- **PASS**: A through E run to the expected outcomes without
  back-channel SQL fixups.
- **FAIL (executor)**: A run that should complete returns
  `status = 'failed'` or `status = 'running'` (suspended without
  reason). Inspect `workflow_run_state.last_error`.
- **FAIL (compiler)**: D doesn't refuse — the permission gate
  is bypassed. This is a release-blocker; the genericity
  invariant G3 has been violated.
- **FAIL (mentions)**: E's stored content doesn't carry the
  `<mentions>` block — the FE sidecar isn't reaching the BE.

## Post-UAT cleanup

```sql
DELETE FROM workflow_run_state;
DELETE FROM workflow_run_waits;
DELETE FROM workflow_versions;
DELETE FROM workflows;
DELETE FROM users WHERE id = 'u_member';
```

(The seeded admin and the default org survive.)
