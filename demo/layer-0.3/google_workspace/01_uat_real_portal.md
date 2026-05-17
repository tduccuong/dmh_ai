# 01 — Google Workspace live-portal UAT script (sales / ops staff)

Six chat prompts the staff user types into DMH-AI to prove the
Google Workspace integration end-to-end against a real Google
Cloud OAuth client. Run after the admin has finished
`CLOUD_SETUP.md` and the staff user has clicked **My Services
→ Connect Google Workspace** through the real consent screen.

Four read prompts come first (safe — never mutate the account).
Then two write prompts that actually create records visible in
Gmail / Drive / Calendar.

## Pre-requisites

- Admin has configured the Google Workspace connector via
  **External Connectors**: Client ID + Secret pasted,
  capabilities ticked (Gmail / Calendar / Drive at minimum;
  add Meet / Tasks / Contacts / Sheets per the prompts below),
  **Enabled** ticked, **Save** + **Test connection** green.
- Staff user has clicked **My Services → Connect Google
  Workspace** and approved the consent screen — the My Services
  panel shows Google Workspace under **Connected** with a green
  badge.
- Chat session is in **Assistant** mode.

## The script

### 1. Read — Gmail search

```
Search my Gmail for messages from anyone at example.com in the last week.
```

Fires `gmail.search` (read). Reply quotes real From / Subject /
Snippet from the staff user's mailbox. Use a domain you know
exists in your inbox — substitute anything for `example.com`.

### 2. Read — Calendar free slots

```
Find me three 30-minute free slots on my Google Calendar over the next 5 business days.
```

Fires `gcal.find_free_slots` (read). Reply lists ISO timestamps
of open blocks in the user's primary calendar.

### 3. Read — Drive listing

```
List the 5 most recent files in my Google Drive root.
```

Fires `drive.list` (read). Reply quotes real file names + MIME
types.

### 4. Read — Contacts lookup

```
Find any Google contacts named "Alex" (or your own family/colleague name).
```

Fires `contacts.search` (read). Reply quotes real contacts —
useful baseline before the calendar-invite write in step 6.

### 5. Write — Send Gmail

```
Send a Gmail to yourself with the subject "DMH-AI UAT — Gmail send" and the body "demo verification — please ignore".
```

Fires `gmail.send` (write, idempotency-keyed). Check the
message appears in the staff user's **Sent** folder within
seconds.

### 6. Write — Create a Calendar event + Meet link

```
Create a Google Calendar event tomorrow at 10:00 for 30 minutes,
titled "DMH-AI UAT meeting", and attach a Google Meet link.
```

Two-tool chain: `gcal.create_event` then `meet.create_meeting`
(if the admin ticked Meet). Check **Google Calendar** —
tomorrow at 10:00 — the event has a `meet.google.com/<id>` join
link in its details.

## What "good" looks like

- Each reply quotes data from the real Google account (not
  generic examples). Specific contact emails, file names, event
  IDs.
- Open the progress tray on the FE — every prompt shows:
    - `CreateTask → <prompt summary>`
    - `ConnectMcp → google_workspace`
    - `GoogleWorkspace.<function>` (one row per function call)
    - `final_text`
- Writes (prompts 5–6) produce records visible in Gmail /
  Calendar within seconds.

## Gotchas

- Only the capabilities ticked in **External Connectors** route
  through. If admin un-ticked Calendar, prompts 2 / 6 hit the
  Layer-3 dispatcher gate and the agent says it can't.
- If the inbox / Drive is empty (test account), reads return
  0 results — that's not an error.
- Gmail's `to:me` quirk: if the staff user's account has
  message-routing rules, the self-send in step 5 may land in a
  label/folder other than Inbox — search the Sent folder to
  confirm.
- A 403 from any function means the Google Cloud project is
  missing the relevant API (Gmail API / Calendar API / Drive
  API / People API / Meet API / Tasks API / Sheets API). The
  agent surfaces the enable URL — click it, enable, retry.
- A 401 means the OAuth refresh token expired (rare — Google
  refresh tokens are long-lived). Staff user re-Connects via
  **My Services**.

## Cleanup after a UAT pass

- Gmail → Sent → search "DMH-AI UAT — Gmail send" → delete.
- Google Calendar → tomorrow → "DMH-AI UAT meeting" → delete
  the event (also cleans up the auto-generated Meet link).

## Demoing this to a customer

1. **Tab A** — admin on `/connectors` showing the Google
   Workspace card with green badges.
2. **Tab B** — staff user, chat session in Assistant mode.
3. Run prompts 1 → 3 → 5 → 6.
4. Switch to the customer's Gmail / Calendar tab and show the
   newly-sent email and the freshly-created event with its
   Meet link.
5. Pitch line:
   > *"Ihr Team durchforstet Gmail und den Kalender nicht mehr
   > manuell — der Agent fragt direkt das Google Workspace ab.
   > Eine Frage, eine Antwort — Mail-Suchen, Slot-Findung,
   > Event-Buchung samt Meet-Link in einem Schritt."*
