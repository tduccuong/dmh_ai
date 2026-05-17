# Layer W — Workflow Authoring Demos

Five worked scenarios for the staff user to feel the workflow
compiler end-to-end. Each scenario is a real SME pattern (sales
follow-up, customer onboarding, invoice dunning, …), structured
in order of increasing complexity so the staff user climbs the
ladder one rung at a time:

| # | Scenario | Connectors | Trigger | Approval | Branches | Wait | Complexity |
|---|---|---|---|---|---|---|---|
| 1 | [Daily inbox digest](./01_daily_inbox_digest.md) | GW | schedule | — | — | — | minimal |
| 2 | [Welcome new HubSpot customer](./02_welcome_new_customer.md) | HubSpot + GW | poll | — | — | — | cross-connector |
| 3 | [Inbound demo request handler](./03_demo_request_handler.md) | GW + HubSpot + Calendly | poll | manager gate | — | — | + approval, + 3rd connector |
| 4 | [Kickoff meeting follow-up](./04_kickoff_with_branching.md) | HubSpot + Calendly + GW | poll | — | yes | yes (7d) | + branch + wait |
| 5 | [Overdue invoice dunning](./05_overdue_invoice_dunning.md) | HubSpot + GW | schedule | conditional | yes (tiered 7/14/30) | — | + multi-branch + conditional gate |

Each runbook is the **canonical example** the compiler should
produce on the first try. Use them as:

- **For staff users** — a menu of starting prompts to try when
  learning the system. Type the *Initial prompt* verbatim, see
  what v0 the compiler emits, refine.
- **For the compiler's training / evaluation** — when iterating
  on the compile-mode system prompt, run these prompts and
  compare the compiler's v0 against the expected IR shape. v0
  may be sparser than the expected final shape; refinement turns
  close the gap.
- **For sales demos** — the *Pitch line* at the bottom of each
  scenario is the one-paragraph framing for the customer
  meeting.

## What this folder is NOT

- **Not a tutorial for writing YAML.** The user types natural
  language; the compiler writes the IR. The YAML in each
  scenario is what the COMPILER produces, shown so the operator
  can verify the shape is sane — the staff user never reads it.
- **Not exhaustive.** Five scenarios cover the basic shapes
  (schedule / poll / approval / branch / wait); real customers
  build dozens, each idiosyncratic.

## Connectors used

- **Google Workspace** — gmail.search / send / reply, gcal,
  drive.upload, tasks, docs.read_text, contacts.search.
- **HubSpot** — contact / company / deal / task / activity.
- **Calendly** — event_type.list / available_slots,
  single_use_link.create, event.list, event.invitees, event.cancel.

Microsoft 365 is intentionally omitted from these demos — same
function shape as Google Workspace; swap connector slug in any
scenario to retarget.

## Pre-requisites for running these

- All three connectors configured in External Connectors
  (Client ID + Secret pasted, Test connection green).
- Staff user has clicked Connect for each of the three via
  My Services.
- The Layer W primitive itself is live in stage (workflow
  compiler tool + viewer modal + workflow store) — until then
  these are read-only design docs.

## Sequencing the demo

If you're sitting with a prospect and have 45 minutes:

1. Scenario 1 (5 min) — proves the chat-only build loop.
2. Scenario 2 (10 min) — proves cross-connector composition.
3. Scenario 3 (15 min) — proves approval gates + 3-vendor chain.
4. Either 4 or 5 (15 min) — depending on whether the prospect
   cares more about customer-facing automation (4) or
   back-office cash-flow automation (5).

Skip scenarios that don't map to their business. The point of
the ladder is not *"show me all five"*; the point is *"show me
the one that maps to my pain."*
