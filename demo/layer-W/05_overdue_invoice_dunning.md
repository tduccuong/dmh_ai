# 05 — Overdue invoice dunning (multi-tier branching)

**The flagship complexity scenario.** Daily-schedule trigger
fires across N matching deals; per-deal subworkflow runs a
three-tier dunning sequence (7 / 14 / 30 days overdue) with
conditional behaviour at each tier based on whether the
customer has responded. Conditional auto-approve gates the
final escalation. ~12 nodes, three branches, two writes per
tier, multi-day audit trail.

Canonical SME pattern per industry research: the 7/14/30-day
cadence (or 30/60/90 for larger B2B contracts) is the
[standard dunning sequence](https://mccarygroup.com/automate-invoice-payment-reminders/);
Stripe reports businesses using full dunning recover 15-25%
more revenue than basic reminder workflows.

## SME pain

The accounts-receivable problem in numbers most SMEs would rather
not see:

- **Aged receivables drift.** *"Are we owed money? Yeah,
  probably. Let me check."* — that's the wrong answer.
- **Polite reminders work — but only if they go out.** Most
  follow-ups die because the bookkeeper has 30 things ahead of
  *"check who owes us money."*
- **Tone needs to escalate.** Day 7 is "friendly nudge"; day 30
  is "formal notice". An SME owner can't draft that scale of
  variations on the fly for every overdue invoice.

The workflow runs once a day, finds every invoice in trouble,
and either nudges / escalates / flags-for-human based on aging
+ response state.

## Connectors involved

- **HubSpot** — deal listing (filter by aging), contact lookup,
  activity log, task create.
- **Google Workspace** — Gmail search (detecting customer
  responses), Gmail send (tiered reminders).

> **Note:** A production-grade dunning workflow would also
> integrate with a payment processor (Stripe in our connector
> set) to check actual paid-status. v0 of this workflow uses
> HubSpot deal stage as a proxy for paid/unpaid; v1+ refinement
> typically adds `stripe.invoice.find` to confirm payment.

## Initial prompt

```
Every weekday at 6 PM, go through HubSpot deals where the deal
stage is "invoice_sent" and close_date was 7+ days ago. For each
overdue invoice:

- If their last response to us was within the last 3 days, skip
  (they're already in a conversation).
- If 7-13 days overdue: send a polite first reminder.
- If 14-29 days overdue: send a firmer second reminder.
- If 30+ days overdue: don't send anything automatically — create
  a task for me with priority HIGH to call the customer myself,
  and log a note that escalation is needed.

Log every step on the deal record in HubSpot.
```

## What the compiler emits — v0 (Label view)

```
Workflow:  overdue_invoice_dunning · v0
Trigger:   Every weekday at 18:00 ("0 18 * * MON-FRI")
           → on each fire, run a sub-workflow per matching deal

[T] Scheduled tick (no per-deal payload yet)
        │
        ▼
[1] Find HubSpot deals in stage "invoice_sent" with close_date older than 7d
        │  emits: {deals: [...]}
        │
        ▼  (workflow forks: one continuation per deal)

  ── per-deal subworkflow ──────────────────────────────────────

  [2] Look up the deal's primary contact
          │  emits: {contact.email, contact.name, contact.company, deal.amount}
          ▼
  [3] Compute days_overdue = (today - {{T.deal.close_date}}) in days
          │
          ▼
  [4] Search Gmail for replies in the last 3 days from {{2.contact.email}}
          │  emits: {recent_response_count}
          │
          ├── recent_response_count > 0  → output_skipped_in_conversation
          └── recent_response_count == 0 → [5]

  [5] BRANCH on days_overdue
          │
          ├── 7 ≤ days_overdue < 14   → [6A]   (gentle first reminder)
          ├── 14 ≤ days_overdue < 30  → [6B]   (firm second reminder)
          └── days_overdue ≥ 30       → [6C]   (escalate — human-only)

  [6A] Send the gentle reminder email
        │
        ▼
  [7A] Log "tier-1 reminder sent" on the deal
        ▼  output_reminded_tier1

  [6B] Send the firm reminder email
        │
        ▼
  [7B] Log "tier-2 reminder sent" on the deal
        ▼  output_reminded_tier2

  [6C] (no email sent)
        │
        ▼
  [7C] Create HubSpot task for me — priority HIGH, due tomorrow
        │  subject: "Call {{2.contact.company}} re: overdue invoice (€{{2.deal.amount}}, {{3.days_overdue}}d)"
        ▼
  [8C] Log "30d+ — escalation requested via task" on the deal
        ▼  output_escalated_to_human
```

## What the compiler emits — v0 (Technical view, abridged)

```yaml
name:         overdue_invoice_dunning
display_name: "Overdue invoice dunning"
version:      0

trigger:
  kind:     schedule
  cron:     "0 18 * * MON-FRI"
  timezone: "{{org.timezone}}"
  fan_out_node: 1                   # node 1's emit is a list; one continuation per element

inputs: []                          # schedule has no payload at trigger time

nodes:
  - id: 1
    function: hubspot.deal.find
    args:
      stage:           "invoice_sent"
      max_close_date:  "{{date_minus_days(today, 7)}}"
      limit:           500
    label:    "Find HubSpot deals invoice_sent + 7d+ since close_date"
    emits:    { deals: "$.deals[*]" }
    fan_out:  true                  # each deal becomes a per-element subworkflow run
    next:     2                     # the per-element scope binds {{T.deal}} to {{1.deals[i]}}

  - id: 2
    function: hubspot.contact.find
    args:     { query: "{{T.deal.contact_id}}", limit: 1 }
    label:    "Look up the deal's primary contact"
    emits:
      contact_email:   "$.contacts[0].email"
      contact_name:    "$.contacts[0].name"
      contact_company: "$.contacts[0].company"
    next: 3

  - id: 3
    function: builtin.compute        # built-in primitive for inline math/date
    args:
      formula: "days_between(today, T.deal.close_date)"
    label: "Compute days_overdue"
    emits: { days_overdue: "$.result" }
    next: 4

  - id: 4
    function: gmail.search
    args:
      query: "from:{{2.contact_email}} newer_than:3d"
      limit: 1
    label:    "Search Gmail for replies in the last 3 days from this customer"
    emits:    { recent_response_count: "$.message_count" }
    next:     4_branch

  - id:    4_branch
    kind:  branch
    label: "Customer already responded in the last 3d?"
    cases:
      - when:  "{{4.recent_response_count}} > 0"
        next:  output_skipped_in_conversation
      - else:
        next:  5

  - id:    5
    kind:  branch
    label: "Bucket by days_overdue"
    cases:
      - when:  "{{3.days_overdue}} >= 7 and {{3.days_overdue}} < 14"
        next:  6A
      - when:  "{{3.days_overdue}} >= 14 and {{3.days_overdue}} < 30"
        next:  6B
      - else:                          # days_overdue >= 30
        next:  6C

  - id: 6A
    function: gmail.send
    args:
      to:      "{{2.contact_email}}"
      subject: "Reminder — invoice for {{T.deal.name}} (€{{T.deal.amount}})"
      body: |
              Hi {{2.contact_name}},

              Just a friendly reminder — invoice for "{{T.deal.name}}"
              (€{{T.deal.amount}}) was due {{3.days_overdue}} days
              ago. Could you confirm when we should expect payment?

              Best, <rep name>
    label: "Send the gentle reminder email"
    emits: { reminder_message_id: "$.id" }
    next:  7A

  - id: 7A
    function: hubspot.activity.log
    args:
      deal_id: "{{T.deal.id}}"
      kind:    "email"
      body:    "tier-1 reminder sent ({{3.days_overdue}}d overdue, id: {{6A.reminder_message_id}})"
    label: "Log tier-1 reminder on the deal"
    next:  output_reminded_tier1

  - id: 6B
    function: gmail.send
    args:
      to:      "{{2.contact_email}}"
      subject: "Second reminder — invoice for {{T.deal.name}}"
      body: |
              Hi {{2.contact_name}},

              We sent a reminder last week regarding the invoice for
              "{{T.deal.name}}" (€{{T.deal.amount}}). It's now
              {{3.days_overdue}} days overdue. Please let us know
              when payment will be made; we want to avoid escalating
              this further.

              Regards, <rep name>
    label: "Send the firm second reminder email"
    emits: { reminder_message_id: "$.id" }
    next:  7B

  - id: 7B
    function: hubspot.activity.log
    args:
      deal_id: "{{T.deal.id}}"
      kind:    "email"
      body:    "tier-2 reminder sent ({{3.days_overdue}}d overdue, id: {{6B.reminder_message_id}})"
    label: "Log tier-2 reminder on the deal"
    next:  output_reminded_tier2

  - id: 6C
    function: hubspot.task.create
    args:
      subject:    "Call {{2.contact_company}} re: overdue invoice (€{{T.deal.amount}}, {{3.days_overdue}}d)"
      body: |
              Invoice for "{{T.deal.name}}" is {{3.days_overdue}} days
              overdue.

              No tier-3 automated email is sent at this stage.
              Recommendation: call them today.
      due_date:   "{{now_plus_days(1)}}"
      task_type:  "call"
      priority:   "high"
      deal_id:    "{{T.deal.id}}"
      contact_id: "{{T.deal.contact_id}}"
    label: "Create high-priority HubSpot task for manual outreach"
    emits: { task_id: "$.task_id" }
    next:  8C

  - id: 8C
    function: hubspot.activity.log
    args:
      deal_id: "{{T.deal.id}}"
      kind:    "note"
      body:    "Invoice {{3.days_overdue}}d overdue — automated dunning stopped, escalation task {{6C.task_id}} created for manual outreach"
    label: "Log 30d+ escalation on the deal"
    next:  output_escalated_to_human

  - id:    output_skipped_in_conversation
    kind:  output
    emit:  { action: "skipped", reason: "recent_response" }

  - id:    output_reminded_tier1
    kind:  output
    emit:  { action: "reminded_tier1", days_overdue: "{{3.days_overdue}}" }

  - id:    output_reminded_tier2
    kind:  output
    emit:  { action: "reminded_tier2", days_overdue: "{{3.days_overdue}}" }

  - id:    output_escalated_to_human
    kind:  output
    emit:  { action: "escalated", task_id: "{{6C.task_id}}" }
```

## Compiler open questions on v0

```
⚠ OQ1 — node 1 emits a LIST of deals; the rest of the workflow
        treats {{T.deal}} as a single deal. This needs a "fan-out"
        primitive: the trigger fires once, then spawns N continuations
        each scoped to one deal. The workflow IR v1 supports this
        via `fan_out: true` on node 1; each spawned continuation runs
        nodes 2-8 as if it were a fresh task. Confirm:
            "fan-out OK"                — proceeds as drafted
            "explain other approaches"  — compiler narrates alternatives

⚠ OQ2 — node 3 uses `builtin.compute` for a date diff. If you'd
        rather have the compiler resolve all date math at planning
        time and not introduce a runtime compute primitive,
        days_overdue can be pre-computed in the trigger query's
        filter and surfaced as part of {{T.deal}}. Reply:
            "use builtin.compute"            — runtime path
            "pre-compute at trigger time"    — static path; less flexible
```

User typically replies `fan-out OK` and `use builtin.compute`. v1
locks both choices.

## Expected refinement turns

| Turn | User says | Compiler does |
|------|-----------|---------------|
| 2 | `fan-out OK`, `use builtin.compute` | Locks the IR shape; compiler explicitly documents the fan-out semantics on node 1 |
| 3 | "Skip deals where the amount is under €100 (not worth dunning)." | Adds a branch after node 2 filtering on `{{T.deal.amount}} >= 100` |
| 4 | "Cross-check with Stripe — if the deal has a Stripe invoice and it's actually marked paid there, skip even though HubSpot still says invoice_sent." | Inserts `stripe.invoice.find` node between 2 and 4; adds a branch on `{{stripe.status}} == 'paid'` |
| 5 | "Add an approval gate before the tier-2 email (don't want to escalate without me seeing it)." | Inserts a `gate` node between 5 and 6B; auto-approve when amount < €1000, manager approval above |
| 6 | "Use the German template for German-speaking customers — detect via the contact's country field." | Inserts a branch after node 2 on `{{2.contact.country}} == 'DE'`; two parallel reminder templates downstream |

## Arming

```
User: "Arm v5 — Stripe paid-check + manager approval on tier-2 ≥ €1000."
Assistant: "v5 active. Will fire weekdays at 18:00 Europe/Berlin.
            Each fire fans out across overdue deals; per-deal task
            runs 2-12 nodes depending on the branch taken. Tier-2
            ≥ €1000 will pause for your approval. Tier-3 always
            creates a manual task — no automated email."
```

## What "good" looks like when it runs

Friday 18:00 example sweep with 8 overdue deals:

| Deal | Days overdue | Recent reply? | Amount | Action taken |
|------|-------------:|---------------|-------:|--------------|
| ACME Q1 |  9 | no  |  €  400 | tier-1 email sent |
| Beta GmbH | 12 | yes |  € 2500 | skipped (in conversation) |
| Gamma AB | 17 | no  |  €  800 | tier-2 email sent (auto, < €1000) |
| Delta Inc | 19 | no  |  € 4200 | **paused on approval gate** (≥ €1000) |
| Epsilon Co | 22 | no  |  €  650 | tier-2 email sent (auto) |
| Zeta SARL | 35 | no  |  € 5800 | tier-3 task created for human |
| Eta KG | 41 | no  |  € 1200 | tier-3 task created for human |
| Theta SA | 8 | no  |  €   60 | skipped (amount < €100, v3 refinement) |

8 deals, 8 tasks under the same workflow root, each pinned to v5.
Audit log shows the full set in the workflow's "recent activity"
view.

## Pitch line

> *"Every Friday at 6 PM, the agent does what your bookkeeper
> usually means to do but doesn't. Polite reminders go out at day
> 7. Firmer ones at day 14. Anything 30 days overdue lands on
> your desk Monday morning as a task to call them personally —
> you never have to ask "are we owed money?" because the agent
> already told you, with the list."*

## What this scenario proves

- **Fan-out works.** One scheduled tick produces N parallel
  workflow runs, one per matching item, each with its own
  audit trail.
- **Multi-tier branches are natural.** The compiler emits clean
  `branch.cases` with range predicates (`days_overdue >= 7 and
  < 14`); users add tiers by adding cases.
- **Conditional approval gates compose.** Auto-approve under a
  threshold; approval-required above. Same primitive as
  scenario 3, applied conditionally.
- **Cross-vendor verification is one step away.** Adding the
  Stripe paid-check (refinement turn 4) is a single inserted
  node, not a re-design.
- **Audit completeness.** Every deal touched, every email sent,
  every task created — all pinned to v5 of the workflow.
  Auditor in a month can reconstruct exactly what fired and
  why.

## Sources for the dunning pattern

- [Automated Invoice Payment Reminders — Step-by-Step Guide (McCary Group)](https://mccarygroup.com/automate-invoice-payment-reminders/)
- [Dunning Management Procedures (Stripe)](https://stripe.com/resources/more/dunning-management-101-why-it-matters-and-key-tactics-for-businesses)
- [Dunning Sequence Definitions (Chargezoom)](https://www.chargezoom.com/blog/what-is-a-dunning-sequence)
- [Automated Reminders for Overdue Invoices (Emagia)](https://www.emagia.com/blog/automated-reminders-for-overdue-invoices/)
