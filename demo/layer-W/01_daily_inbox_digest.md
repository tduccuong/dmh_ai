# 01 — Daily inbox digest

**The simplest possible workflow** — one connector, one
schedule trigger, three nodes, no approvals, no branches. The
"hello world" of workflow authoring; proves the chat-only build
loop in under five minutes.

## SME pain

Operations managers / owners check Gmail 30 times a day looking
for "did anyone urgent email me?" — most of those checks return
nothing. An 8am digest of unread emails matching a few patterns
(known clients, the words *urgent / ASAP / by today*) replaces
the constant inbox-anxiety check.

## Connectors involved

- **Google Workspace** only.

## Initial prompt (staff user types in chat)

```
Every weekday at 8 AM, scan my Gmail for unread emails from the
last 16 hours. Flag anything from known clients or containing
"urgent" / "ASAP" / "by today", and email me a one-paragraph
summary with subject lines + sender names.
```

## What the compiler emits — v0 (Label view)

```
Workflow:  daily_inbox_digest · v0
Trigger:   Every weekday at 8:00 AM

[1] Search Gmail for unread emails received in the last 16 hours
        │
        ▼
[2] Compose a one-paragraph summary highlighting urgent + known-client emails
        │
        ▼
[3] Email the summary to me

Output:    {sent: true, count_summarised: <integer>}
```

## What the compiler emits — v0 (Technical view)

```yaml
name:           daily_inbox_digest
display_name:   "Daily inbox digest"
version:        0

trigger:
  kind:     schedule
  cron:     "0 8 * * MON-FRI"
  timezone: "{{org.timezone}}"

inputs: []                                    # schedule has no payload

nodes:
  - id:       1
    kind:     step
    function: gmail.search
    args:
      query: "is:unread newer_than:16h"
      limit: 25
    label:    "Search Gmail for unread emails received in the last 16 hours"
    emits:    { messages: "$.messages" }
    next:     2

  - id:       2
    kind:     step
    function: llm.compose
    args:
      template: "inbox_digest"
      context:
        messages: "{{1.messages}}"
        flag_terms: ["urgent", "ASAP", "by today"]
        known_clients_kb: "kb://contacts/known_clients"
    label:    "Compose a one-paragraph summary highlighting urgent + known-client emails"
    emits:    { summary_html: "$.html", count: "$.count" }
    next:     3

  - id:       3
    kind:     step
    function: gmail.send
    args:
      to:      "{{org.me.email}}"
      subject: "Inbox digest — {{T.date}}"
      body:    "{{2.summary_html}}"
    label:    "Email the summary to me"
    emits:    { message_id: "$.id" }
    next:     output_ok

  - id:       output_ok
    kind:     output
    label:    "Sent"
    emit:
      sent:              true
      count_summarised:  "{{2.count}}"

outputs:
  - { name: sent,              source: "{{output_ok.sent}}" }
  - { name: count_summarised,  source: "{{output_ok.count_summarised}}" }
```

## Expected refinement turns

The first prompt is intentionally simple; staff users usually add
nuance in subsequent turns. Typical refinements:

| Turn | User says                                                         | Compiler does                          |
|------|-------------------------------------------------------------------|----------------------------------------|
| 2    | "Skip newsletters and calendar invites."                          | adds `-from:newsletter AND -invite.ics` to node 1's query |
| 3    | "If nothing matched, don't email me an empty digest."             | wraps node 3 in a branch on `{{2.count}} > 0` |
| 4    | "Run it Saturday morning too at 9 AM."                            | edits trigger.cron to `0 8 * * MON-FRI, 0 9 * * SAT` |
| 5    | "Send the digest as plain text, not HTML."                        | edits node 2's template to a plain-text variant |

Each refinement → new version (v1, v2, …) → new link in chat → click to inspect.

## Arming the workflow

```
User: "Arm v3."
Assistant: "v3 active. First fire: Monday 08:00 Europe/Berlin.
            Schedule trigger requires no vendor configuration —
            DMH-AI's scheduler will dispatch on the next tick."
```

## What "good" looks like when it runs

- Next Monday at 08:00, a silent task opens in the user's task
  list, runs nodes 1 → 2 → 3, completes, and an email appears in
  the user's inbox titled *"Inbox digest — 2026-05-18"*.
- The digest paragraph quotes 1–10 senders + subject lines, with
  ⚠ icons next to urgent / known-client emails.
- The audit log shows one row per fire, pinned to v3.

## Pitch line

> *"You don't open Gmail for the first time at 8 AM looking for
> urgent emails — you check the digest DMH-AI emails you at 8 AM
> and only open Gmail if it says you need to. One workflow, five
> minutes to build, ten minutes a day of attention saved."*

## What this scenario proves

- **The chat-only build loop works.** User describes → compiler
  emits → user clicks → modal opens → user refines → loop.
- **Schedule triggers fire reliably.** No vendor setup, no
  reachability requirement, works on every deployment.
- **Single-connector workflows are real workflows.** Not every
  SME needs cross-vendor — sometimes the value is just "do this
  thing every day on time."
