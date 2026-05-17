# 04 — Kickoff meeting follow-up (branches + wait)

**Async, branching, multi-day.** Introduces the `wait` node
(workflow suspends until a vendor event fires OR a timeout
elapses) and the `branch` node (different downstream steps
based on what happened during the wait). This is the first
scenario whose execution spans days rather than seconds — the
shape every Layer-3 use case wants.

## SME pain

After a deal closes-won, the rep sends a Calendly link for a
kickoff meeting. Two failure modes:

- **Customer books promptly** → kickoff happens, business
  proceeds, everyone's happy. Manual follow-up after the
  meeting often slips ("did the rep send the project plan?").
- **Customer doesn't book** → the link languishes in their
  inbox. After a week, the deal is technically closed-won but
  nothing has happened. The rep didn't follow up because
  nobody told them to.

The fix is a workflow that watches whether the booking
happened and forks behaviour accordingly.

## Connectors involved

- **HubSpot** — trigger source, contact lookup, task creation,
  activity log.
- **Calendly** — single-use link, listening for booking event.
- **Google Workspace** — Gmail send (initial link + reminder).

## Initial prompt

```
When a deal closes-won in HubSpot, send the customer a Calendly
link for a kickoff meeting. If they book within 7 days, schedule
me a "send project plan" task to fire the day after their
meeting. If they don't book within 7 days, send them a friendly
reminder email and ping me to do manual outreach.
```

## What the compiler emits — v0 (Label view)

```
Workflow:  kickoff_followup · v0
Trigger:   Poll HubSpot every 5 min for deals closed-won in the last poll window

[T] HubSpot deal closed-won
        │  emits: {deal.id, deal.contact_id, deal.name}
        ▼
[1] Look up the contact + their email
        │  emits: {contact.email, contact.name, contact.company}
        ▼
[2] List my Calendly event types, pick "Kickoff"
        │  emits: {event_type_uri}
        ▼
[3] Create a single-use Calendly link
        │  emits: {booking_url}
        ▼
[4] Send the booking link to the customer
        │  emits: {sent_message_id}
        ▼
[5] Log "kickoff link sent" on the deal in HubSpot
        │
        ▼
[6] WAIT up to 7 days for the customer to book
        │  fires on:    calendly.invitee.created matching {{3.booking_url}}
        │  emits on fire: {event_uri, scheduled_start_time}
        │
        ├── on fire    → [7]    (booked)
        └── on timeout → [9]    (no booking in 7 days)

[7] Log "kickoff scheduled for {{scheduled_start_time}}" on the deal
        │
        ▼
[8] Create HubSpot task "Send project plan to {{1.contact.company}}"
        │  due_date: {{6.scheduled_start_time}} + 1 day
        ▼
        output_booked

[9] Send the customer a friendly reminder + the same booking link
        │
        ▼
[10] Create a HubSpot task for me: "Follow up manually with {{1.contact.company}}"
        │  due_date: tomorrow, priority: high
        ▼
[11] Log "no kickoff booking after 7d, reminder sent + manual task created" on the deal
        ▼
        output_unbooked
```

## What the compiler emits — v0 (Technical view, abridged)

```yaml
name:         kickoff_followup
display_name: "Kickoff meeting follow-up"
version:      0

trigger:
  kind:           poll
  every_seconds:  300
  source:         hubspot.deal.find
  filter:
    stage:        "closedwon"
    min_updated:  "{{state.last_check}}"
  emits:
    deal:
      id:         string
      contact_id: string
      name:       string

inputs:
  - { name: "deal.id",         type: string }
  - { name: "deal.contact_id", type: string }
  - { name: "deal.name",       type: string }

nodes:
  - id: 1
    function: hubspot.contact.find
    args:     { query: "{{T.deal.contact_id}}", limit: 1 }
    label:    "Look up the contact + their email"
    emits:
      contact_email:   "$.contacts[0].email"
      contact_name:    "$.contacts[0].name"
      contact_company: "$.contacts[0].company"
    next: 2

  - id: 2
    function: calendly.event_type.list
    args:     {}
    label:    "List my Calendly event types, pick \"Kickoff\""
    emits:
      event_type_uri: "$.event_types[?(@.name ~= 'kickoff|onboarding')].uri | first"
    next: 3

  - id: 3
    function: calendly.single_use_link.create
    args:
      event_type_uri:  "{{2.event_type_uri}}"
      max_event_count: 1
    label:    "Create a single-use Calendly link"
    emits:    { booking_url: "$.booking_url" }
    next: 4

  - id: 4
    function: gmail.send
    args:
      to:      "{{1.contact_email}}"
      subject: "Let's get you kicked off — pick a time"
      body:    |
                 Hi {{1.contact_name}},

                 Welcome to <our company>! Please pick a time
                 for our kickoff call here: {{3.booking_url}}

                 Looking forward to it.
    label:    "Send the booking link to the customer"
    emits:    { sent_message_id: "$.id" }
    next: 5

  - id: 5
    function: hubspot.activity.log
    args:
      deal_id: "{{T.deal.id}}"
      kind:    "email"
      body:    "Kickoff Calendly link sent: {{3.booking_url}}"
    label:    "Log \"kickoff link sent\" on the deal in HubSpot"
    next: 6

  - id: 6
    kind:  wait
    label: "WAIT up to 7 days for the customer to book"
    trigger:
      kind:  webhook
      event: calendly.invitee.created
      match: "owner = {{3.booking_url}}"   # the invitee's link must match the one we sent
    timeout_seconds: 604800                  # 7 days
    on_fire:    7
    on_timeout: 9
    emits_on_fire:
      event_uri:            "$.uri"
      scheduled_start_time: "$.start_time"
      invitee_email:        "$.invitee.email"

  - id: 7
    function: hubspot.activity.log
    args:
      deal_id: "{{T.deal.id}}"
      kind:    "meeting"
      body:    "Kickoff scheduled for {{6.scheduled_start_time}} (invitee: {{6.invitee_email}})"
    label:    "Log \"kickoff scheduled\" on the deal"
    next: 8

  - id: 8
    function: hubspot.task.create
    args:
      subject:    "Send project plan to {{1.contact_company}}"
      body:       "Their kickoff was {{6.scheduled_start_time}}."
      due_date:   "{{date_add(6.scheduled_start_time, days=1)}}"
      task_type:  "todo"
      priority:   "high"
      deal_id:    "{{T.deal.id}}"
    label:    "Create HubSpot task \"Send project plan to {{1.contact_company}}\""
    next: output_booked

  - id: 9
    function: gmail.send
    args:
      to:      "{{1.contact_email}}"
      subject: "Re: your kickoff with <our company>"
      body:    |
                 Hi {{1.contact_name}},

                 Just bumping this — happy to find a time that
                 works for you. Same link: {{3.booking_url}}

                 If that link doesn't work for you, reply to
                 this and we'll sort something out.
    label:    "Send the customer a friendly reminder + same booking link"
    emits:    { reminder_message_id: "$.id" }
    next: 10

  - id: 10
    function: hubspot.task.create
    args:
      subject:    "Follow up manually with {{1.contact_company}}"
      body:       "They didn't book the kickoff in 7 days. Try a call?"
      due_date:   "{{now_plus_days(1)}}"
      task_type:  "call"
      priority:   "high"
      deal_id:    "{{T.deal.id}}"
    label:    "Create a HubSpot task for me: \"Follow up manually\""
    next: 11

  - id: 11
    function: hubspot.activity.log
    args:
      deal_id: "{{T.deal.id}}"
      kind:    "note"
      body:    "7d kickoff window elapsed; reminder sent (id: {{9.reminder_message_id}}) + manual task created."
    label:    "Log no-booking outcome on the deal"
    next: output_unbooked

  - id:    output_booked
    kind:  output
    label: "Booked — kickoff scheduled"
    emit:
      booked:               true
      scheduled_start_time: "{{6.scheduled_start_time}}"

  - id:    output_unbooked
    kind:  output
    label: "Unbooked after 7d — manual outreach queued"
    emit:
      booked:               false
      reminder_message_id:  "{{9.reminder_message_id}}"
      manual_task_id:       "{{10.task_id}}"
```

## Compiler open question on v0

```
⚠ OQ1 — node 6 (WAIT) uses the Calendly webhook event
        `invitee.created`. This requires the Calendly webhook
        capability, which is currently :planned in the connector
        ticker. Phase-A fallback: poll Calendly every 5 minutes
        for the booking via calendly.event.list filtered by
        `event_type_uri` and `min_start_time > now`. Latency: up
        to 5 minutes after the customer books. Reply:
            "use webhook (block on capability)" — workflow can't arm yet
            "use poll fallback"                — workflow runs now with 5-min lag
```

User replies `use poll fallback` → v1 swaps node 6's trigger to a
poll-based wait.

## Expected refinement turns

| Turn | User says | Compiler does |
|------|-----------|---------------|
| 2 | `use poll fallback` for the wait | Rewrites node 6 to use `kind: poll` with `calendly.event.list` matching the booking URL |
| 3 | "If they book, also schedule me a prep task for 1 hour before the meeting." | Inserts node 7.5 — `hubspot.task.create` with `due_date = scheduled_start_time - 1h` |
| 4 | "Wait 10 days not 7." | Edits node 6's `timeout_seconds` to `864000` |
| 5 | "Send the reminder at day 4, not after 7." | Restructures: adds a wait at day 4 → branch on booked-yet? → send-reminder or continue-waiting-until-day-7 |

## Arming

```
User: "Arm v3."
Assistant: "v3 active. Polling HubSpot every 5 min for new closed-won deals.
            Each fire opens a workflow that runs for up to 7 days,
            durably suspended on node 6's wait. Calendly booking
            detection is poll-based until Calendly webhook lands;
            5-min booking-detection lag."
```

## What "good" looks like when it runs

**Booked-within-7-days case:**

- T+0: deal closes; workflow opens; nodes 1–5 run; node 6 suspends.
- T+3 days: customer clicks the Calendly link, books a slot.
- T+3 days + 5 min: poll-fallback detects the booking; workflow
  resumes at node 7; activity logged; task created with the
  scheduled date.
- T+3 days + 5 min + 1 day = task fires in the rep's HubSpot
  Tasks queue.

**Unbooked-after-7-days case:**

- T+0: deal closes; workflow opens; nodes 1–5 run; node 6 suspends.
- T+7 days: wait times out; workflow resumes at node 9;
  reminder email sent; manual-followup task created.
- Audit log shows the full 7-day suspension as one continuous task.

## Pitch line

> *"You close a deal on Monday. By Friday, either the kickoff is
> on the calendar with a prep task queued — or the agent sent a
> reminder and put a 'call them personally' task on your dashboard.
> No deal sits silent for two weeks because nobody remembered to
> check."*

## What this scenario proves

- **Workflows survive days.** The `wait` node is durable —
  process restart, DB backup, server reboot — the task picks up
  where it left off.
- **Branches model real-life forks.** Most SME workflows have
  *"if happened: branch A, else: branch B"* — they're not pure
  pipelines.
- **Phase A → Phase B is gracefully degraded.** Poll fallback
  on Calendly works today (5-min lag); webhook upgrade is a
  trigger.kind flip with no IR re-design.
- **Workflows compose with the regular task surface.** The
  HubSpot tasks the workflow creates appear in the rep's
  normal task list — no separate UI for "agent-created" vs
  "human-created" work.
