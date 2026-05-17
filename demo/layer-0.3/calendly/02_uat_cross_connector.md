# 02 — Cross-connector live UAT (HubSpot + Calendly)

The headline demo for the framework — one chat turn chains
five function calls across two real vendors. Proves the agent
*composes* connectors, not just calls them.

Run this after both `hubspot/01_uat_real_portal.md` and
`calendly/01_uat_real_portal.md` pass cleanly on their own.
Cross-connector debugging is materially harder when one of the
two connectors is itself broken.

## Pre-requisites

- Admin has configured **both** connectors via External
  Connectors: Client ID + Secret pasted, capabilities ticked,
  **Enabled**, **Test connection** green for both.
- Sales / scheduling user has clicked **My Services → Connect
  HubSpot** AND **My Services → Connect Calendly** — both show
  under **Connected** with green badges.
- The connected HubSpot portal has **at least one real contact
  who could plausibly book a discovery call**. For the script
  below, replace `Brian Kunde` with that real contact's name.
- The connected Calendly account has at least **one active
  event type** named something the agent can match on (e.g.
  *"Discovery Call"*, *"30 min intro"*, *"Erstgespräch"*).
- Chat session is in **Assistant** mode.

## The script

### The one-prompt demo

```
<contact name> wants a 30-minute discovery call next week.
Find them in HubSpot, send a one-time Calendly link for my
discovery event type, log it on their deal, and schedule a
follow-up task for me 3 days after the meeting.
```

The agent walks the chain:

```
1. hubspot.contact.find(query: "<contact name>")
     → returns contact_id + associated deal_id (if any)

2. calendly.event_type.list()
     → picks the discovery / intro event type by name match

3. calendly.single_use_link.create(event_type_uri: <…>)
     → returns booking_url

4. hubspot.activity.log(deal_id: <…>, kind: "email",
                        body: "Sent Calendly link: <booking_url>")
     → returns activity_id

5. hubspot.task.create(subject: "Follow up with <contact> post-discovery",
                       due_date: <+3d ISO>,
                       deal_id: <…>,
                       priority: "medium",
                       task_type: "todo")
     → returns task_id
```

Two connectors, five functions, one chat turn. No custom
workflow code — the agent composes from the function catalogue
based on the prompt.

## What "good" looks like

- The final reply quotes the **real Calendly booking URL** (a
  `calendly.com/d/…` shortlink) and the **real HubSpot deal id**
  + **task id** the writes produced.
- Open the progress tray on the FE — you should see all five
  function rows with `done` status, interleaved with the two
  `ConnectMcp` rows (one per vendor):
  ```
  CreateTask
  ConnectMcp (hubspot)
  HubSpot.contact.find
  ConnectMcp (calendly)
  Calendly.event_type.list
  Calendly.single_use_link.create
  HubSpot.activity.log
  HubSpot.task.create
  final_text
  ```
- In the **HubSpot UI**, the contact's activity timeline shows
  the Note with the booking URL embedded; the Task appears in
  the rep's Task list with the +3d due date.
- In the **Calendly UI** → **Single-use links**, the new link
  appears.

## Gotchas

- **Contact lookup misses** — if the HubSpot contact's name in
  the portal is spelled differently from the prompt (umlauts,
  abbreviations, married/maiden), `contact.find` returns 0
  results and the chain stops. Either fix the prompt or fix
  the portal record.
- **Event-type-name heuristic** — the agent picks the Calendly
  event type by keyword match. If the user has multiple similar
  event types (*"30 min discovery"* vs *"30 min intro"*), the
  match is ambiguous and the agent may pick the wrong one.
  Workaround: name the event type explicitly in the prompt
  (*"my 30 min discovery event type"*) and the agent passes
  the name through verbatim.
- **Capability tick mismatch** — if admin un-ticked Tasks or
  Activities on HubSpot, steps 4 + 5 fail at the dispatcher
  gate and the final reply omits them silently. Check the
  progress tray for `not_in_catalog` errors.
- **Free-tier Calendly limits** — single-use links are capped
  per month on Free / Standard plans. Reset on billing cycle.
- **Time-zone drift in `due_date`** — the agent computes
  +3 days from "today" in the server's TZ; if the rep's
  HubSpot account is in a different TZ, the task may show one
  day off. Live with it, or specify the due date explicitly in
  the prompt.

## Cleanup after a UAT pass

- HubSpot UI → find the test contact → **Activities** → delete
  the note created in step 4. **Tasks** → delete the task
  created in step 5.
- Calendly UI → **Single-use links** → delete the link from
  step 3 (or let it expire naturally after one booking).

## Demoing this to a customer

### Day-before staging

Run the prompt once with a real test contact in your own
HubSpot. Confirm all five rows show `done` and the final reply
quotes the booking URL. Note the response time (typically
45–60s with the LLM round-trips between function calls).

Open three browser tabs on the demo machine:
- **Tab A** — DMH-AI admin on `/connectors`, both HubSpot +
  Calendly cards showing green badges.
- **Tab B** — sales user, chat session pre-created in
  Assistant mode.
- **Tab C** *(optional)* — the customer's own HubSpot UI tab
  on the contact's record. So they see the Note + Task appear
  in real time.

### In the meeting

1. **Tab A.** Point at the two connector cards.
   > *"Hier sehen Sie: zwei Vendor-Surfaces, gleicher
   > Admin-Bildschirm — HubSpot fürs CRM, Calendly fürs
   > Scheduling. Beide sprechen dasselbe interne Protokoll mit
   > DMH-AI."*
2. **Tab B.** Type the chained prompt with a real contact
   name. Hit enter.
3. **While the agent runs** (~45–60s), open the progress tray.
   Narrate each row as it appears.
4. **When the final reply lands**, copy the booking URL,
   switch to **Tab C** (customer's HubSpot UI), refresh the
   contact's activity timeline — the Note + Task are there.
5. Re-open Tab A and point at one connector's **OAuth scope**
   row:
   > *"Beide brauchen eine OAuth-Genehmigung pro Nutzer —
   > einmalig — danach läuft jede Frage über genau die
   > Capabilities, die wir hier abgehakt haben. Kein
   > Backdoor-Admin-Zugriff."*

### The pitch in one paragraph

> *"Jeder Anbieter da draußen verkauft Ihnen *N* Integrationen.
> Wir verkaufen Ihnen die *Komposition*. Eine Frage, der Agent
> bewegt sich zwischen Ihren Tools — CRM, Scheduling, E-Mail,
> Files — als wäre es ein System. Ihr Vertrieb klickt nicht
> mehr durch fünf Tabs. Ihre CSM-Mannschaft auch nicht. Der
> Agent macht es. Mit *Ihren* Daten, in *Ihren* Systemen, mit
> *Ihren* OAuth-Berechtigungen."*

## Variations once the base chain works

Same architecture, different prompts — no code changes:

- **Calendly + GW**: *"Schick mir eine Vorbereitungs-Mail per
  Gmail für jeden Calendly-Termin diese Woche."* →
  `event.list` → `gmail.send` per event.
- **HubSpot + GW**: *"Für jeden offenen HubSpot-Deal lade
  unsere Pricing-Sheet hoch und verschicke es per Gmail."* →
  `deal.find` → `drive.upload` → `gmail.send`.
- **HubSpot + M365**: *"Lege für jeden HubSpot-Lead einen
  Outlook-Kontakt an."* → `contact.find` (HubSpot) →
  `contacts.search` + (planned) M365 contact write.

These are the same agent + the same framework + the same admin
screen. New cross-connector flows don't require new agent
logic — they require new vendor surfaces to compose over.

## Known gaps

- **No task-due-date passthrough from Calendly** — Calendly's
  booking doesn't tell us when the meeting will happen (the
  invitee picks later). The follow-up task's due date is
  therefore "+3d from today" (= link-send date), not "+3d
  from the meeting". A correct version needs Calendly's
  `invitee.created` webhook (Layer D — planned, separate epic).
- **Sequential, not parallel** — five function calls take
  30–60s with the LLM round-trips between them. Layer-C batching
  (e.g. HubSpot's `batch/create`) would shrink some of those,
  but cross-vendor sequencing can't be batched.
- **No automatic rollback** — if step 4 succeeds but step 5
  fails, the Note is created and the Task isn't. The agent
  reports the partial state in the final reply but doesn't
  unwind the Note. Designed-as: the framework prioritises
  visibility over atomicity (Rule 3's idempotency_key carries
  retry semantics, not transactions).
