# 01 — Calendly live-portal UAT script (staff)

Five chat prompts the user types into DMH-AI to prove the
Calendly integration end-to-end against a real Calendly account.
Run after the admin has finished `CALENDLY_APP_SETUP.md` and the
user has clicked **My Services → Connect Calendly** through the
real consent screen.

Three read prompts come first (safe — never mutate the
account). Then two write prompts that actually create or cancel
records visible in the Calendly UI.

## Pre-requisites

- Admin has configured the Calendly connector via **External
  Connectors**: Client ID + Secret pasted, capabilities ticked
  (Scheduling links + Meetings + User identity at minimum),
  **Enabled** ticked, **Save** + **Test connection** green.
- The connected Calendly user has at least **one active event
  type** (e.g. a "Discovery Call — 30 min"). Calendly returns
  empty arrays for `event_type.list` on accounts with none.
- User has clicked **My Services → Connect Calendly** and
  approved the consent screen — the My Services panel shows
  Calendly under **Connected** with a green badge.
- Chat session is in **Assistant** mode (not Confidant).

## The script

### 1. Read — whoami

```
Which Calendly account am I connected to?
```

Fires `user.me` (read, no idempotency key). Reply quotes the
real connected user's email + timezone + scheduling URL.

### 2. Read — my event types

```
What scheduling links do I have in Calendly?
```

Fires `event_type.list` (read). Reply lists real event type
names + durations + their public booking URLs.

### 3. Read — upcoming meetings

```
What meetings are on my Calendly for the next 7 days?
```

Fires `event.list` with `min_start_time` = today,
`max_start_time` = today+7d. Reply quotes real invitee names
+ event names + start times. (If nothing is booked, the reply
says so — that's not an error.)

### 4. Write — single-use link

```
Create a one-time Calendly link for my 30-minute discovery
event type.
```

Two-tool chain: `event_type.list` (the agent picks the
"discovery" event type by name match) → `single_use_link.create`
(idempotency-keyed). Reply quotes the new booking URL — open it
in an incognito tab to verify it loads Calendly's booking page.

### 5. Write — cancel a meeting

```
Cancel my next Calendly meeting. Reason: "rescheduling for the
following week."
```

Two-tool chain: `event.list` (find the next event) →
`event.cancel` (POST cancellation with the reason). Calendly
emails the invitee a cancellation notice carrying the reason
verbatim. Check **Calendly → Scheduled events** — the event
moves from *"Active"* to *"Canceled"* within seconds.

## What "good" looks like

- Each reply quotes data from the real account (not generic
  examples). Specific event names, real invitee emails, real
  start times.
- Open the progress tray on the FE — every prompt shows:
    - `CreateTask → <prompt summary>`
    - `ConnectMcp → calendly`
    - `Calendly.<function>` (one row per function call)
    - `final_text`
- Writes (prompts 4–5) produce visible side effects in
  Calendly's UI / emails within seconds.

## Gotchas

- Only the capabilities ticked in **External Connectors** route
  through. If admin un-ticked Meetings, prompts 3 + 5 hit the
  Layer-3 dispatcher gate and the agent says it can't.
- If the user is on Calendly Free, `single_use_link.create`
  may return 422 — Calendly free accounts have limits on
  single-use links per month. Reset on the next billing cycle.
- A 401 from any function means the user's access token expired
  and refresh failed. User re-Connects via **My Services**.
- Calendly's organization-scope endpoints (group admin,
  activity log) return 403 unless the connected user is a
  Calendly org admin — DMH-AI maps that to `:unauthorised`.
  These capabilities are in the ticker as `:planned` and not
  yet exposed as functions.

## Cleanup after a UAT pass

- The single-use link from step 4 expires automatically after
  one booking. No cleanup needed unless you actually want to
  delete it — Calendly → Single-use links → delete.
- The cancellation from step 5 is a real cancellation — the
  invitee got an email. For demo-only passes, schedule a fake
  event with yourself (or a colleague) as invitee before
  running the script, so the cancellation doesn't surprise a
  real contact.

## Demoing this to a customer

1. **Tab A** — admin on `/connectors` showing the Calendly card
   with green badges + the 8 planned capabilities greyed out.
   The *"this is how I curated the capabilities — three live,
   eight more in the roadmap"* beat.
2. **Tab B** — user, chat session in Assistant mode.
3. **Tab C** — the customer's Calendly UI tab, on the
   **Scheduled events** page.
4. Run prompts 1 → 2 → 4 in Tab B, then switch to Tab C and
   show the new single-use link in Calendly's UI.
5. Pitch line:
   > *"Ihre Vertriebs- oder CSM-Mitarbeiter wechseln nicht
   > mehr in Calendly, um Termin-Links zu kopieren. Eine
   > Frage im Chat, der Agent wählt den richtigen Termintyp,
   > erzeugt den Link, schickt ihn — fertig. Mit dem gleichen
   > Schienensystem, das Sie schon für Google Workspace oder
   > Microsoft 365 oder HubSpot kennen."*
