# HubSpot Public App setup for DMH-AI

One-page checklist for the admin wiring DMH-AI to a real
HubSpot portal — 10–15 minutes of clicks in HubSpot's Developer
Portal plus pasting the result into DMH-AI's External Connectors
page. Required before the live-portal UAT script in
`01_uat_real_portal.md`.

## Pre-requisites

- A HubSpot Developer account (free at `developers.hubspot.com`)
  with the ability to create Public Apps.
- One HubSpot portal to install the app into for testing (the
  same Developer account gets a free test portal you can use).
- DMH-AI stage URL known (e.g. `http://localhost:8080` for local;
  the OAuth callback path is fixed at `/oauth/callback`).

## Steps

### 1. Create a Public App

1. Sign in at <https://developers.hubspot.com/>.
2. **Apps** → **Create app** → **Public app**.
3. **App info**:
    - Name: *"DMH-AI CRM connector"* (or similar).
    - Description, logo, URL — fill anything; the user-facing
      consent screen surfaces this.

### 2. Configure Auth (the OAuth-relevant tab)

1. **Auth** tab → **Redirect URLs** → copy the value from
   DMH-AI's External Connectors page (the **OAuth Redirect URI**
   field with the copy button). For local stage it'll be
   `http://localhost:8080/oauth/callback`. For production it'll
   be `https://<your-dmh-ai-host>/oauth/callback`.
2. Note the **Client ID** and **Client secret** at the top of
   the Auth tab — copy both. (Secret is visible only here; if
   you lose it, re-generate.)

### 3. Add Scopes

In the **Auth** tab → **Scopes** section, add the scopes that
match the capabilities you want to expose:

| Capability you tick in DMH-AI | HubSpot scopes to add |
|---|---|
| Contacts | `crm.objects.contacts.read`, `crm.objects.contacts.write` |
| Deals | `crm.objects.deals.read`, `crm.objects.deals.write` |
| Activities | `crm.objects.deals.write` (already covered by Deals) |

Tick exactly the scopes the install URL will request — HubSpot
rejects the URL on the smallest mismatch. The External Connectors
page shows the per-capability scope list under each "Capabilities
to expose" row; tick those same identifiers in HubSpot's portal.

### 4. Install the app into a test portal

1. **Auth** tab → bottom → copy the **install URL** HubSpot
   generates from the scopes you selected.
2. Paste that URL in a browser, sign in to your test portal,
   approve. After install you can see the app under your
   portal's **Settings → Integrations → Connected Apps**.
3. This step is so you have a real portal to OAuth into when
   you test the DMH-AI staff flow.

### 5. Paste credentials into DMH-AI

1. Log in to DMH-AI as the admin.
2. **External Connectors** (`/connectors`) → **HubSpot**.
3. **Capabilities to expose** — tick which subset your org will use.
4. **Client ID** + **Client Secret** — paste from step 2.
5. **MCP URL** — leave at the in-process default
   (`http://127.0.0.1:8087/hubspot`) unless you point at a
   different host.
6. Tick **Enabled** → **Save** → **Test connection**.

### 6. Sales staff connects their HubSpot portal

1. Sales user logs in to DMH-AI.
2. **My Services** → **Connect HubSpot**.
3. New tab opens to HubSpot's consent screen — they see the
   capability scopes you ticked in step 3.
4. Approve → tab closes → DMH-AI chat shows the green
   "HubSpot connected" toast.

## Common errors

| Symptom | Likely cause |
|---|---|
| HubSpot consent screen shows *"Invalid redirect_uri"* | The URL in step 2.1 doesn't match what DMH-AI sends. Re-check exact scheme/host/port/path. |
| Consent succeeds, chat reply says `missing_credentials` for `hubspot` | OAuth flow didn't complete the credential write. Check `user_credentials` for the `target='oauth:hubspot'` row. |
| Read functions return empty arrays but write functions succeed | The portal you connected to has no contacts/deals matching the model's query — try a wider search, or create a deal first. |
| Chat reply says `api_disabled` with a hubspot.com link | The Public App's scope set doesn't include the scope the function needs. Add the scope in step 3, ask user to re-Connect. |

## Rotating credentials

1. Developer Portal → your app → **Auth** → **Reset client secret**.
2. Copy new secret.
3. DMH-AI → External Connectors → HubSpot → paste new secret in
   **Client Secret** → **Save**.
4. Click **Test connection**.

## Decommissioning

- User-side: **My Services** → **Disconnect HubSpot**. Drops
  `authorized_services` + credential rows.
- Portal-side: HubSpot portal → **Settings → Integrations →
  Connected Apps** → uninstall.
- Developer-side: Developer Portal → app → delete (revokes all
  active grants across every install).
