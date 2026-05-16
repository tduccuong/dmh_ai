# 02 — Microsoft 365 live-portal UAT script (sales / ops staff)

Six chat prompts the staff user types into DMH-AI to prove the
real Microsoft Graph integration end-to-end. Use this when
the connector is wired to a **real Microsoft Entra app
registration** (not the mock vendor MCP) — i.e. after the admin
has finished `AZURE_SETUP.md` and the staff user has clicked
**My Services → Connect Microsoft 365** through the real
consent screen.

Four read prompts come first (safe — never mutate the tenant).
Then two write prompts that actually create records visible in
Outlook / OneDrive / Teams.

## Pre-requisites

- Admin has configured the Microsoft 365 connector via
  **External Connectors**: Client ID + Secret pasted,
  capabilities ticked (Mail / Calendar / Files at minimum; add
  Teams / To Do / Contacts / Excel per the prompts below),
  **Enabled** ticked, **Save** + **Test connection** green.
- Staff user has clicked **My Services → Connect Microsoft
  365** and approved the consent screen — the My Services panel
  shows Microsoft 365 under **Connected** with a green badge.
- Chat session is in **Assistant** mode.

## The script

### 1. Read — Outlook mail search

```
Search my Outlook for messages from anyone at example.com in the last week.
```

Fires `mail.search` (read; uses Graph KQL `$search` with the
`ConsistencyLevel: eventual` header). Reply quotes real From /
Subject / Snippet from the staff user's mailbox. Substitute
`example.com` with a domain you know exists in your inbox.

### 2. Read — Calendar free slots

```
Find me three 30-minute free slots on my Outlook calendar over the next 5 business days.
```

Fires `cal.find_free_slots` (read; over Graph `getSchedule`
with 30-minute availability blocks). Reply lists ISO timestamps
of open blocks.

### 3. Read — OneDrive listing

```
List the 5 most recent files in my OneDrive root.
```

Fires `files.list` (read). Reply quotes real file names + MIME
types.

### 4. Read — Contacts lookup

```
Find any Outlook contacts named "Alex" (or your own family/colleague name).
```

Fires `contacts.search` (read). Reply quotes real contacts
from the user's personal contacts.

### 5. Write — Send Outlook mail

```
Send an Outlook email to myself with subject "DMH-AI UAT — Mail send" and body "demo verification — please ignore".
```

Fires `mail.send` (write, idempotency-keyed). Check the
message appears in the staff user's **Outlook Sent Items**
within seconds.

### 6. Write — Create a calendar event + Teams meeting

```
Create an Outlook event tomorrow at 10:00 for 30 minutes,
titled "DMH-AI UAT meeting", and attach a Microsoft Teams link.
```

Two-tool chain: `cal.create_event` then `teams.create_meeting`
(if the admin ticked Teams). Check **Outlook Calendar** —
tomorrow at 10:00 — the event has a `teams.microsoft.com/...`
join link in its details.

## What "good" looks like

- Each reply quotes data from the real Microsoft account (not
  generic examples). Specific contact emails, file names, event
  IDs.
- Open the progress tray on the FE — every prompt shows:
    - `CreateTask → <prompt summary>`
    - `ConnectMcp → m365`
    - `M365.<function>` (one row per function call)
    - `final_text`
- Writes (prompts 5–6) produce records visible in Outlook /
  Teams within seconds.

## Gotchas

- Only the capabilities ticked in **External Connectors** route
  through. If admin un-ticked Calendar, prompts 2 / 6 hit the
  Layer-3 dispatcher gate and the agent says it can't.
- If the mailbox / OneDrive is empty (test account), reads
  return 0 results — that's not an error.
- `mail.search` requires the `ConsistencyLevel: eventual`
  header — the MCPHandler adds it automatically. If the search
  returns 0 rows on a populated mailbox, the query string
  matched nothing (KQL is strict — try a broader term).
- `files.upload` is small-file PUT only (<4 MB). For larger
  uploads the user gets a Graph error — track as a known gap.
- A 403 from any function means the Microsoft Entra app
  registration is missing the relevant Graph permission. The
  agent surfaces the consent URL — admin re-grants, then user
  re-Connects via **My Services**.
- A 401 means the OAuth refresh token expired (rare).
  Staff user re-Connects.
- For SMEs that picked **Single-tenant** in Entra, the
  authority URL needs the tenant id — see `AZURE_SETUP.md`
  for the RPC override (FE field for this is a future polish).

## Cleanup after a UAT pass

- Outlook → Sent Items → search "DMH-AI UAT — Mail send" →
  delete.
- Outlook Calendar → tomorrow → "DMH-AI UAT meeting" → delete
  the event (also cleans up the Teams meeting + chat).

## Demoing this to a customer

1. **Tab A** — admin on `/connectors` showing the Microsoft
   365 card with green badges.
2. **Tab B** — staff user, chat session in Assistant mode.
3. Run prompts 1 → 3 → 5 → 6.
4. Switch to the customer's Outlook / Teams tab and show the
   newly-sent email and the freshly-created event with its
   Teams join link.
5. Pitch line:
   > *"Ihr Team durchforstet Outlook und den Kalender nicht
   > mehr manuell — der Agent fragt direkt Microsoft Graph
   > ab. Eine Frage, eine Antwort — Mail-Suchen,
   > Slot-Findung, Event-Buchung samt Teams-Link in einem
   > Schritt."*
