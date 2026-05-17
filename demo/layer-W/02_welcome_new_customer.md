# 02 — Welcome new HubSpot customer

**Cross-connector basic.** Two vendors (HubSpot + Google
Workspace), poll trigger, no approval, no branches — but
five chained nodes whose state flows forward through Mustache
references. Proves the framework composes connectors.

## SME pain

When a sales rep moves a HubSpot deal to *closed-won*, four
things happen manually:

1. Create a customer folder in Google Drive (for files,
   contracts, deliverables).
2. Email the customer a welcome note with their account info.
3. Create an internal Tasks reminder: "kickoff call within 7 days".
4. Log the activity in HubSpot so the deal record shows the
   onboarding started.

Across a typical week with 5 new customers, this is 1–2 hours
of clicking the rep keeps forgetting parts of.

## Connectors involved

- **HubSpot** — trigger source + activity log + task create.
- **Google Workspace** — Drive folder, Gmail send.

## Initial prompt

```
When a HubSpot deal moves to closed-won, set the customer up:
create a Google Drive folder named after their company, send
them a welcome email, and add a HubSpot task for me to schedule
their kickoff call within 7 days. Log everything on the deal.
```

## What the compiler emits — v0 (Label view)

```
Workflow:  welcome_new_customer · v0
Trigger:   Poll HubSpot every 5 minutes for deals moved to "closedwon"
           in the last poll window

[T] HubSpot deal closed-won detected
        │  emits: {deal.id, deal.contact_id, deal.amount, deal.name}
        ▼
[1] Look up the deal's contact in HubSpot
        │  emits: {contact.email, contact.name, contact.company}
        ▼
[2] Create a Google Drive folder named "{{1.contact.company}} — Customer"
        │  emits: {folder.id, folder.url}
        ▼
[3] Send a welcome email to the customer with the folder link
        │  emits: {message.id}
        ▼
[4] Create a HubSpot Task: "Kickoff call with {{1.contact.company}}" due in 7 days, linked to the deal
        │  emits: {task.id}
        ▼
[5] Log a HubSpot note on the deal summarising the steps taken

Output:    {folder_url, welcome_message_id, task_id}
```

## What the compiler emits — v0 (Technical view, abridged)

```yaml
name:         welcome_new_customer
display_name: "Welcome new HubSpot customer"
version:      0

trigger:
  kind:           poll
  every_seconds:  300
  source:         hubspot.deal.find
  filter:
    stage:         "closedwon"
    min_updated:   "{{state.last_check}}"
  emits:
    deal:
      id:         string
      contact_id: string
      amount:     number
      name:       string

inputs:
  - { name: "deal.id",         type: string }
  - { name: "deal.contact_id", type: string }
  - { name: "deal.amount",     type: number }
  - { name: "deal.name",       type: string }

nodes:
  - id:       1
    function: hubspot.contact.find
    args:     { query: "{{T.deal.contact_id}}", limit: 1 }
    label:    "Look up the deal's contact in HubSpot"
    emits:
      contact_email:   "$.contacts[0].email"
      contact_name:    "$.contacts[0].name"
      contact_company: "$.contacts[0].company"
    next:     2

  - id:       2
    function: drive.upload
    args:
      name:      "{{1.contact_company}} — Customer/.placeholder"
      content:   "Folder created by DMH-AI on {{now}} for deal {{T.deal.name}}"
      mime_type: "text/plain"
    label:    "Create a Google Drive folder named \"{{1.contact_company}} — Customer\""
    emits:
      folder_id:  "$.id"
      folder_url: "$.webViewLink"
    next:     3

  - id:       3
    function: gmail.send
    args:
      to:      "{{1.contact_email}}"
      subject: "Welcome to <our company> — your customer folder"
      body:    |
                 Hi {{1.contact_name}},

                 Welcome aboard! Your customer folder is here:
                 {{2.folder_url}}

                 I'll be in touch within 7 days to schedule your kickoff call.

                 — <rep name>
    label:    "Send a welcome email to the customer with the folder link"
    emits:    { message_id: "$.id" }
    next:     4

  - id:       4
    function: hubspot.task.create
    args:
      subject:    "Kickoff call with {{1.contact_company}}"
      body:       "First customer-success touch; introduce the team."
      due_date:   "{{now_plus_days(7)}}"
      task_type:  "call"
      priority:   "high"
      deal_id:    "{{T.deal.id}}"
      contact_id: "{{T.deal.contact_id}}"
    label:    "Create a HubSpot Task: \"Kickoff call with {{1.contact_company}}\" due in 7 days"
    emits:    { task_id: "$.task_id" }
    next:     5

  - id:       5
    function: hubspot.activity.log
    args:
      deal_id: "{{T.deal.id}}"
      kind:    "note"
      body: |
              DMH-AI onboarding workflow ran:
              • Drive folder: {{2.folder_url}}
              • Welcome email sent (id: {{3.message_id}})
              • Kickoff task created (id: {{4.task_id}}, due {{now_plus_days(7)}})
    label:    "Log a HubSpot note on the deal summarising the steps taken"
    emits:    { activity_id: "$.activity_id" }
    next:     output_ok

  - id:    output_ok
    kind:  output
    label: "Onboarded"
    emit:
      folder_url:         "{{2.folder_url}}"
      welcome_message_id: "{{3.message_id}}"
      task_id:            "{{4.task_id}}"

outputs:
  - { name: folder_url,         source: "{{output_ok.folder_url}}" }
  - { name: welcome_message_id, source: "{{output_ok.welcome_message_id}}" }
  - { name: task_id,            source: "{{output_ok.task_id}}" }
```

## Expected refinement turns

| Turn | User says | Compiler does |
|------|-----------|---------------|
| 2 | "The email should come from the deal owner, not me." | Adds a node before 3 to look up the deal owner via `hubspot.deal.find`, uses owner's email as the `from` parameter on `gmail.send` |
| 3 | "Skip the email if the contact opted out of marketing." | Wraps node 3 in a branch on `{{1.opted_in}}` (compiler adds a `marketing_status` field to node 1's emits + a HubSpot property fetch) |
| 4 | "Set the task due to 5 business days, not 7 calendar days." | Edits node 4's `due_date` to `{{now_plus_business_days(5)}}` |

## Arming

```
User: "Arm v3."
Assistant: "v3 active. Polling HubSpot every 5 minutes for new closed-won
            deals. (Instant trigger requires HubSpot webhook capability,
            currently :planned — see roadmap.) First run on the next deal
            close."
```

## What "good" looks like when it runs

- Within 5 minutes of a deal closing in HubSpot, the silent task
  appears in the audit log; the customer's Drive folder exists;
  the customer's inbox has the welcome email; the deal record
  shows a new task + a note.
- Re-running on the same deal (idempotency, retry-safe): each
  step's idempotency_key prevents duplicate Drive folders, duplicate
  emails, duplicate tasks.

## Pitch line

> *"Closed-won is a moment, not a status — five things should
> happen the instant it does. They happen automatically now.
> Your rep moves the deal stage; the agent does the rest. The
> customer sees a welcome email with their folder link 30 seconds
> later. Your CS team sees the kickoff task already in their queue."*

## What this scenario proves

- **Cross-connector composition.** State flows from HubSpot →
  GW → HubSpot through Mustache references.
- **Poll triggers cover everything.** Until HubSpot webhook
  capability lands, the 5-minute lag is the only difference vs
  instant; nobody notices in practice.
- **Idempotency works at scale.** The same deal arriving twice
  doesn't create two welcome emails.
