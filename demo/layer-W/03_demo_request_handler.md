# 03 — Inbound demo request handler

**Approval gate + three-vendor chain.** Adds Calendly as a
third connector, adds a manager-approval gate before any
customer-facing send, and shows the agent extracting structured
data (sender email, requested time) from natural-language Gmail
content. Proves the framework gates human-approved writes
correctly inside a multi-vendor chain.

## SME pain

Demo requests arrive via Gmail in three shapes:

- *"Can we book a call to see your product?"* (generic intent).
- *"Are you free Thursday at 3 PM?"* (specific time).
- *"<reply-all on a long thread asking about pricing>"* (buried,
  hard to triage).

Sales reps catch maybe 60% of these inside the SLA; the rest
sit in the inbox for a day. Booking-link response time matters
more than the actual demo conversation — a 30-minute response
wins the deal vs a 24-hour response.

## Connectors involved

- **Google Workspace** — Gmail search (trigger source) + Gmail
  reply.
- **HubSpot** — contact upsert + activity log.
- **Calendly** — event type list + single-use link create.

## Initial prompt

```
When someone emails me asking about a demo or discovery call,
look them up in HubSpot (create them if they're new), send them
a one-time Calendly link for my discovery event type, log the
activity on their deal record. Ask me to approve the email
before it goes out (in case I want to add a personal note).
```

## What the compiler emits — v0 (Label view)

```
Workflow:  demo_request_handler · v0
Trigger:   Poll Gmail every 5 minutes for unread emails matching
           "demo" OR "discovery call" OR "book a call"

[T] Inbound demo request email
        │  emits: {message.id, from.email, from.name, subject, body, thread_id}
        ▼
[1] Look up the sender in HubSpot by email
        │  emits: {found, contact.id, contact.name, company, deal_id}
        ├── found? yes → [3]
        └── found? no  → [2]
[2] Create the contact in HubSpot
        │  emits: {contact.id}
        ▼ ───────────────────────►
[3] List my Calendly event types
        │  emits: {event_type_uri}  (pick the "Discovery" one by name match)
        ▼
[4] Create a single-use Calendly link
        │  emits: {booking_url}
        ▼
[5] Draft the reply email (paste the link, friendly tone)
        │  emits: {draft.body, draft.subject}
        ▼
[6] APPROVAL GATE — show me the draft, ask "send as-is or edit?"
        │
        ├── on approve → [7]
        └── on reject  → output_rejected
[7] Send the reply via Gmail (in-thread)
        │  emits: {message_id}
        ▼
[8] Log a HubSpot activity on the contact's deal (or open one if none)
        │  emits: {activity_id}
        ▼
output_sent  {booking_url, message_id, activity_id}
```

## What the compiler emits — v0 (Technical view, abridged)

```yaml
name:         demo_request_handler
display_name: "Inbound demo request handler"
version:      0

trigger:
  kind:           poll
  every_seconds:  300
  source:         gmail.search
  filter:
    query:        "(demo OR \"discovery call\" OR \"book a call\") is:unread newer_than:1h"
    limit:        20
  emits:
    message:
      id:         string
      from_email: string
      from_name:  string
      subject:    string
      body:       string
      thread_id:  string

nodes:
  - id:       1
    function: hubspot.contact.find
    args:     { query: "{{T.message.from_email}}", limit: 1 }
    label:    "Look up the sender in HubSpot by email"
    emits:
      found:        "$.contacts[0] != null"
      contact_id:   "$.contacts[0].id"
      contact_name: "$.contacts[0].name"
      company:      "$.contacts[0].company"
    next:     1_branch

  - id:    1_branch
    kind:  branch
    cases:
      - when:  "{{1.found}} == true"
        next:  3
      - else:  2

  - id:       2
    function: hubspot.contact.create
    args:
      email:      "{{T.message.from_email}}"
      first_name: "{{llm.guess_first_name(T.message.from_name)}}"
      last_name:  "{{llm.guess_last_name(T.message.from_name)}}"
    label:    "Create the contact in HubSpot"
    emits:    { contact_id: "$.contact_id" }
    next:     3

  - id:       3
    function: calendly.event_type.list
    args:     {}
    label:    "List my Calendly event types"
    emits:
      event_type_uri:  "$.event_types[?(@.name ~= 'discovery|intro')].uri | first"
    next:     4

  - id:       4
    function: calendly.single_use_link.create
    args:
      event_type_uri:  "{{3.event_type_uri}}"
      max_event_count: 1
    label:    "Create a single-use Calendly link"
    emits:    { booking_url: "$.booking_url" }
    next:     5

  - id:       5
    function: llm.compose
    args:
      template: "demo_reply"
      context:
        sender_name:  "{{T.message.from_name}}"
        booking_url:  "{{4.booking_url}}"
        original:     "{{T.message.body}}"
    label:    "Draft the reply email (paste the link, friendly tone)"
    emits:
      draft_subject: "$.subject"
      draft_body:    "$.body"
    next:     6

  - id:       6
    kind:     gate
    label:    "Show me the draft, ask 'send as-is or edit?'"
    approver:
      role:    member                 # self-approve; the requester IS the approver
    timeout_seconds: 86400             # 24 hours
    on_approve: 7
    on_reject:  output_rejected
    on_timeout: output_timeout

  - id:       7
    function: gmail.reply
    args:
      thread_id:              "{{T.message.thread_id}}"
      in_reply_to_message_id: "{{T.message.id}}"
      to:                     "{{T.message.from_email}}"
      subject:                "{{5.draft_subject}}"
      body:                   "{{6.edited_body OR 5.draft_body}}"
    label:    "Send the reply via Gmail (in-thread)"
    emits:    { message_id: "$.id" }
    next:     8

  - id:       8
    function: hubspot.activity.log
    args:
      deal_id: "{{1.deal_id OR (2.contact_id will need deal)}}"
      kind:    "email"
      body:    "Sent Calendly link in reply to '{{T.message.subject}}': {{4.booking_url}}"
    label:    "Log a HubSpot activity on the contact's deal"
    emits:    { activity_id: "$.activity_id" }
    next:     output_sent

  - id:    output_sent
    kind:  output
    label: "Sent"
    emit:
      booking_url:  "{{4.booking_url}}"
      message_id:   "{{7.message_id}}"
      activity_id:  "{{8.activity_id}}"

  - id:    output_rejected
    kind:  output
    label: "Rejected — no email sent"
    emit:  { sent: false, reason: "user_rejected" }

  - id:    output_timeout
    kind:  output
    label: "Approval timed out — no email sent"
    emit:  { sent: false, reason: "approval_timeout" }
```

## Compiler open question on v0

```
⚠ OQ1 — node 8 references {{1.deal_id}} but the HubSpot contact-find
        function returns only contact-level fields; if the contact
        has no existing deal, where should the activity be logged?
        Options:
          (a) skip the activity log when no deal exists
          (b) open a new deal (stage="newdeal") + log there
          (c) log against the contact directly (planned function,
              not yet exposed)
        Reply: "node 8 = (a)" / "(b)" / "(c)".
```

User replies `node 8 = (b)` → v1 adds a `hubspot.deal.create` step
before node 8 with `name = "Demo request from {{1.contact_name}}"`.

## Expected refinement turns

| Turn | User says | Compiler does |
|------|-----------|---------------|
| 2 | "node 8 = (b)" | Inserts new step 7.5 — `hubspot.deal.create` (newdeal stage); node 8's `deal_id` now references 7.5 |
| 3 | "Auto-approve when the email is from one of our existing contacts." | Adds `auto_approve_when: "{{1.found}} == true"` to node 6 |
| 4 | "Skip the workflow entirely if the email body is shorter than 30 chars (probably spam)." | Adds a `branch` node between T and 1 filtering on `len({{T.message.body}}) >= 30` |
| 5 | "Move the polling cadence to 2 minutes during weekdays 9-18, keep it 15 minutes outside that." | Edits trigger to use two cron rules with different `every_seconds` (advanced; may need user-explained intent) |

## Arming

```
User: "Arm v3 — auto-approve for existing contacts, 24h timeout
       for new ones."
Assistant: "v3 active. Polling Gmail every 5 min. Existing contacts:
            no gate (fully autonomous). New contacts: pause for your
            approval up to 24h. If timeout hits, no email sent and
            workflow exits clean."
```

## What "good" looks like when it runs

- A demo email arrives at 10:14; at 10:18 (next poll tick), a
  silent task opens, runs nodes 1–6, **pauses at the gate**.
- The user receives a notification (per Outbound Channels
  Primitive 0.5): *"Workflow demo_request_handler paused on
  approval gate — review the draft reply to <sender>?"*.
- User opens the FE approval surface, sees the draft, either:
  - Clicks Approve → workflow resumes at node 7 → email sent
    within seconds.
  - Edits the body inline → submits → workflow resumes with the
    edited body.
  - Clicks Reject → workflow ends, no email sent.
- The HubSpot deal record shows the new activity logged.

## Pitch line

> *"Demo requests are won in the first 30 minutes. You don't have
> 30 minutes to spare every time one lands. The agent drafts the
> reply, picks the right Calendly link, queues it for your
> one-tap approval. You glance at it, tap, done. The customer
> has a booking link in their inbox before they've finished
> reading your competitor's pitch."*

## What this scenario proves

- **Three-vendor chains run inside one task.** GW → HubSpot →
  Calendly → GW → HubSpot, with state flowing through bindings.
- **Approval gates are first-class.** They pause the workflow,
  notify the right human, resume on the human's action. Same
  Primitive 0.4 plumbing as Layer 2 manual recipes — the
  compiler emits gate nodes naturally.
- **The agent extracts structure from unstructured input.**
  Gmail body → contact name guess + intent classification, all
  done by the LLM step the compiler inserts when it sees prose.
- **Conditional auto-approval is easy.** "Auto-approve when X"
  becomes a one-line attribute on the gate node; no new
  primitive.
