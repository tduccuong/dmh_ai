# 01 — HubSpot live-portal UAT script (sales staff)

Five chat prompts the sales user types into DMH-AI to prove the
HubSpot integration end-to-end against a real HubSpot Public
App. Run after the admin has finished `HUBSPOT_APP_SETUP.md`
and the sales user has clicked **My Services → Connect
HubSpot** through the real consent screen.

Three read prompts come first (safe — never mutate the portal).
Then two write prompts that actually create records visible in
the HubSpot UI.

## Pre-requisites

- Admin has configured the HubSpot connector via **External
  Connectors**: Client ID + Secret pasted, capabilities ticked
  (Contacts at minimum; Deals + Activities for prompts 2–3 and
  5), **Enabled** ticked, **Save** + **Test connection** green.
- Sales user has clicked **My Services → Connect HubSpot** and
  approved the consent screen — the My Services panel shows
  HubSpot under **Connected** with a green badge.
- Chat session is in **Assistant** mode (not Confidant).

## The script

### 1. Read — list recent contacts

```
List the 3 most recent contacts in our HubSpot.
```

Fires `contact.find` (read, no idempotency key). Reply quotes
real contact names + email from the portal.

### 2. Read — open pipeline

```
Show me a few open deals in our HubSpot pipeline.
```

Fires `deal.find` (read). Reply quotes real deal names + amounts.

### 3. Read — stage filter

```
Find any HubSpot deals in the qualifiedtobuy stage.
```

Fires `deal.find` with `stage="qualifiedtobuy"`. Reply lists
deals in that stage, or *"no deals matching"* if the portal has
none. (HubSpot default stage IDs: `appointmentscheduled`,
`qualifiedtobuy`, `presentationscheduled`, `decisionmakerboughtin`,
`contractsent`, `closedwon`, `closedlost`.)

### 4. Write — create a contact

```
Create a HubSpot contact: Test User, email test+demo+<N>@example.com.
```

Replace `<N>` with a fresh integer each test pass — HubSpot
409s on duplicate email and the connector maps that to a
`:duplicate` envelope. Fires `contact.create`. Check the new
record appears under **HubSpot → Contacts** within seconds.

### 5. Write — chained deal + note

```
Open a HubSpot deal worth €1000 for that contact and log a note
"demo verification" on it.
```

Two-tool chain: `deal.create` (links to the contact created in
step 4), then `activity.log` (Notes engagement attached to the
new deal). Check **HubSpot → Sales → Deals**: the new deal shows
the linked contact and the note in its activity timeline.

## What "good" looks like

- Each reply quotes data from the real portal (not generic
  examples). Specific names, emails, deal IDs.
- Open the progress tray on the FE — every prompt shows:
    - `CreateTask → <prompt summary>`
    - `ConnectMcp → hubspot`
    - `HubSpot.<function>` (one row per function call)
    - `final_text`
- Writes (prompts 4–5) produce records visible in HubSpot's UI
  within seconds.

## Gotchas

- Only the capabilities ticked in **External Connectors** route
  through. If admin un-ticked Deals, prompts 2/3/5 hit the
  Layer-3 dispatcher gate and the agent says it can't (the
  function isn't in its catalog).
- If the portal is empty, reads return 0 results — that's not
  an error. Run prompt 4 (a write) first, then re-run the reads.
- `contact.create` 409s on duplicate email — always use a fresh
  `test+demo+<N>@example.com` per pass.
- A 401 from any function means the user's access token expired
  and refresh failed (rare — HubSpot refresh-token grants last
  ~6 months). Sales user re-Connects via **My Services**.

## Cleanup after a UAT pass

- HubSpot → Contacts → filter by `test+demo+` → delete the test
  contacts created in step 4 (cascades to the linked deals).
- HubSpot → Sales → Deals → filter by name "€1000" or similar
  → bulk delete.

## Demoing this to a customer

1. **Tab A** — admin on `/connectors` showing the HubSpot card
   with green badges. The *"this is how I curated the
   capabilities"* beat.
2. **Tab B** — sales user, chat session in Assistant mode.
3. Run prompts 1 → 2 → 4 → 5 (skip prompt 3 unless the customer
   asks about stage filtering).
4. Switch to the customer's HubSpot UI tab and show the new
   contact + deal + note that DMH-AI just created.
5. Pitch line:
   > *"Ihr Vertriebsteam scannt HubSpot nicht mehr manuell.
   > Eine Frage, eine Antwort, der Agent kümmert sich um die
   > Klickwege durch HubSpot — mit dem gleichen Schienensystem,
   > das Sie schon für Google Workspace oder Microsoft 365
   > kennen."*
