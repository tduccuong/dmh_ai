# Calendly OAuth App setup for DMH-AI

One-page checklist for the admin wiring DMH-AI to a real
Calendly account — 5–10 minutes of clicks in Calendly's
Developer Portal plus pasting the result into DMH-AI's
External Connectors page. Required before the live-portal UAT
script in `01_uat_real_portal.md`.

## Pre-requisites

- A Calendly account that can create OAuth apps. **Note**:
  individual / Free plans on Calendly *cannot* create OAuth apps
  — you need at least the **Standard** tier or a Calendly
  Developer account.
- DMH-AI stage URL known (e.g. `http://localhost:8080` for local;
  the OAuth callback path is fixed at `/oauth/callback`).

## Steps

### 1. Create an OAuth app

1. Sign in at <https://developer.calendly.com/>.
2. **My apps** → **New app**.
3. **App info**:
    - Name: *"DMH-AI scheduling connector"* (or similar).
    - Description, logo, support URL — fill anything; the
      user-facing consent screen surfaces these.

### 2. Configure Auth

1. **OAuth** tab → **Redirect URI(s)** → copy the value from
   DMH-AI's External Connectors page (the **OAuth Redirect URI**
   field with the copy button). For local stage it'll be
   `http://localhost:8080/oauth/callback`. For production it'll
   be `https://<your-dmh-ai-host>/oauth/callback`.
2. Note the **Client ID** and **Client secret** at the top of
   the OAuth tab — copy both. (Secret is visible only here; if
   you lose it, re-generate.)

### 3. Scopes

Calendly's OAuth uses a single coarse `default` scope that
covers the full v2 API for the connected user. There's no
per-object scope split, so no per-capability scope mapping like
HubSpot or Google. The capability ticks in DMH-AI gate
*function visibility*, not vendor-side authorization.

That said: organization-level functions (group members,
activity log, etc.) require the connected user to be an
**organization admin** in Calendly. Regular users connecting
through the same OAuth app see those endpoints return 403 —
DMH-AI maps that to `:unauthorised`.

### 4. Install / test the app yourself

1. **OAuth** tab → bottom → grab the **install URL** Calendly
   generates from your config.
2. Paste it in a browser, sign in, approve. After install you
   can see the app under your account's **Integrations** page.
3. This step is so you have a real account to OAuth into when
   you test the DMH-AI staff flow.

### 5. Paste credentials into DMH-AI

1. Log in to DMH-AI as the admin.
2. **External Connectors** (`/connectors`) → **Calendly**.
3. **Capabilities to expose** — tick which groups your org will
   use (Scheduling links + Meetings + User identity is the
   typical starter set).
4. **Client ID** + **Client Secret** — paste from step 2.
5. **MCP URL** — leave at the in-process default
   (`http://127.0.0.1:8087/calendly`) unless you point at a
   different host.
6. Tick **Enabled** → **Save** → **Test connection**.

### 6. Staff connects their Calendly account

1. User logs in to DMH-AI.
2. **My Services** → **Connect Calendly**.
3. New tab opens to Calendly's consent screen — they see the
   single `default` scope.
4. Approve → tab closes → DMH-AI chat shows the green
   "Calendly connected" toast.

## Common errors

| Symptom | Likely cause |
|---|---|
| Calendly consent screen shows *"Invalid redirect URI"* | The URL in step 2.1 doesn't match what DMH-AI sends. Re-check exact scheme/host/port/path. |
| Consent succeeds, chat reply says `missing_credentials` for `calendly` | OAuth flow didn't complete the credential write. Check `user_credentials` for the `target='oauth:calendly'` row. |
| `event_type.list` returns 0 event types | The connected user has no active event types in their Calendly account — create one in Calendly's UI first. |
| `single_use_link.create` returns 422 with *"max_event_count must be 1"* | Calendly free / Standard tiers limit single-use links to one booking. Pass `max_event_count: 1` (the default). |
| Organization-scope functions return `:unauthorised` | The connected user isn't an org admin in Calendly. Either re-Connect as an admin, or scope the capability tick to per-user functions only. |

## Rotating credentials

1. Developer Portal → your app → **OAuth** → **Reset client secret**.
2. Copy new secret.
3. DMH-AI → External Connectors → Calendly → paste new secret in
   **Client Secret** → **Save**.
4. Click **Test connection**.

## Decommissioning

- User-side: **My Services** → **Disconnect Calendly**. Drops
  `authorized_services` + credential rows.
- Account-side: Calendly account → **Integrations** → uninstall.
- Developer-side: Developer Portal → app → delete (revokes all
  active grants).
