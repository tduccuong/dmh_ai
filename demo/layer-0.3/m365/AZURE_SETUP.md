# Microsoft Entra / Azure AD setup for DMH-AI's Microsoft 365 connector

One-page checklist for the admin switching DMH-AI from the mock
vendor MCP (deterministic, demo-friendly) to real Microsoft 365
(production / live UAT). 10–15 minutes of clicks in the Microsoft
Entra admin centre plus pasting the result into DMH-AI's External
Connectors page.

## Pre-requisites

- A Microsoft Entra (Azure AD) tenant with admin rights to register
  applications. A test tenant from a free Microsoft 365 developer
  subscription works.
- DMH-AI stage URL is known (e.g. `https://stage.your-company.example`
  or `http://localhost:8080` for local). The OAuth callback path
  is fixed at `/oauth/callback`.

## Steps

### 1. Register the application

1. Open **<https://entra.microsoft.com/>** → **Applications →
   App registrations** → **New registration**.
2. **Name**: *"DMH-AI Connector"* (or any name).
3. **Supported account types**: pick the one that fits your
   deployment scope:
    - *Single tenant* — only your org's users connect.
    - *Multitenant* — any work / school account can connect.
    - *Multitenant + personal Microsoft accounts* — also `@outlook.com` etc.
   For most SME deployments **Single tenant** is correct.
4. **Redirect URI**: pick *Web* and paste your DMH-AI callback:
   ```
   http://localhost:8080/oauth/callback
   ```
   The URI must match EXACTLY what DMH-AI sends — host, port,
   path, scheme. For production at a real domain use
   `https://<your-dmh-ai-host>/oauth/callback` AND update
   `AgentSettings.oauth_redirect_base_url` so the BE emits the
   same URI.
5. Click **Register**.

### 2. Note the IDs

On the app's **Overview** page copy:
- **Application (client) ID** — this is your "Client ID" for DMH-AI.
- **Directory (tenant) ID** — needed only if you picked
  *Single tenant* above; in that case override DMH-AI's default
  `common` endpoint with your tenant ID (see step 5).

### 3. Create a client secret

1. **Certificates & secrets** → **New client secret**.
2. **Description**: *"DMH-AI stage"*.
3. **Expires**: 24 months is typical; whatever your org rotates on.
4. Click **Add**.
5. **Copy the Value field IMMEDIATELY** — Microsoft only shows it
   once. This is your "Client Secret" for DMH-AI.

### 4. Add Microsoft Graph API permissions

1. **API permissions** → **Add a permission** → **Microsoft Graph** →
   **Delegated permissions**.
2. Add ALL of these (search by name in the picker; they're all under
   the Graph delegated set):
   ```
   Mail.Read
   Mail.Send
   Calendars.Read
   Calendars.ReadWrite
   Files.Read
   Files.ReadWrite
   offline_access     ← REQUIRED for refresh tokens; without it the user
                       has to re-Connect every 60 minutes.
   User.Read
   ```
3. Click **Add permissions**.
4. **Grant admin consent** for the tenant (single-tenant
   deployments) — without this, users see the consent screen on
   first Connect and have to grant individually. Most SMEs prefer
   admin-consented so users get one-tap Connect.

### 5. Paste credentials into DMH-AI

1. Log in to DMH-AI as the admin.
2. Click the user-menu icon → **External Connectors** (or
   navigate directly to `/connectors`).
3. Click **Microsoft 365** in the sidebar.
4. **Capabilities to expose** — tick the subset your org will use
   (Mail / Calendar / Files). Untick what's not needed; the
   consent screen and tool catalog narrow accordingly.
5. **Client ID** — paste the Application (client) ID from step 2.
6. **Client Secret** — paste the secret value from step 3.
7. **MCP URL** — leave as the default if running the in-process
   MCPServer (it's pre-seeded to
   `http://127.0.0.1:8087/m365`). Override only if pointing at
   a different host.
8. Tick **Enabled** if not already.
9. Click **Save** → **Test connection**.

### 6. Single-tenant override (optional)

If you picked *Single tenant* in step 1, the default OAuth flow
hits Microsoft's `common` endpoint which works but is broader
than necessary. For a slightly tighter UAT, after step 5 edit
the `oauth_catalog` row:

```bash
docker exec dmh_ai-master /app/bin/dmh_ai rpc "
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  tenant = \"<your-tenant-id>\"
  query!(Repo, \"\"\"
    UPDATE oauth_catalog
       SET authorization_endpoint = ?,
           token_endpoint         = ?
     WHERE slug = ?
  \"\"\", [
    \"https://login.microsoftonline.com/\" <> tenant <> \"/oauth2/v2.0/authorize\",
    \"https://login.microsoftonline.com/\" <> tenant <> \"/oauth2/v2.0/token\",
    \"m365\"
  ])
  IO.puts(\"tenant override set\")
"
```

### 7. Sales staff connect their own M365 account

1. Sales staff logs in to DMH-AI as their employee account.
2. User-menu → **My Services**.
3. **Connect Microsoft 365** → browser redirects to Microsoft's
   consent screen — they see only the scopes the admin enabled.
4. Approve.
5. Returns to DMH-AI with "✓ Microsoft 365 connected".
6. Open assistant-mode chat and ask one of the demo scenarios.

## Common errors

| Symptom | Likely cause |
|---|---|
| Microsoft shows *"AADSTS50011: The redirect URI specified in the request does not match"* | Redirect URI in step 1.4 doesn't match the stage host. Re-check exact scheme/host/port/path. |
| User consent screen lists scopes you didn't ask for | App registration's API permissions include extras. Remove them in step 4. |
| Chat reply says `missing_credentials` | OAuth flow didn't complete — check `user_credentials` table. Should have a row at `target='oauth:m365'`. |
| Chat reply says `unauthorised` after 1h | `offline_access` not in scopes — refresh isn't happening. Re-check step 4. |
| Chat reply says `api_disabled` with a Graph URL hint | API permissions weren't admin-consented. Run step 4's "Grant admin consent" + ask user to re-Connect. |

## Rotating credentials

To rotate the client secret (e.g. quarterly):

1. **Certificates & secrets** → **New client secret**.
2. Copy the new value.
3. In DMH-AI's **External Connectors** → **Microsoft 365** → paste
   the new secret in **Client Secret** (leave **Client ID** blank
   to keep the existing one) → **Save**.
4. Click **Test connection** to confirm.
5. Delete the OLD secret in Entra (under the same blade) once the
   new one is in use.

## Decommissioning

To stop allowing DMH-AI to act on a user's Microsoft 365 account:

- User-side: **My Services** → **Disconnect Microsoft 365**.
  Drops `authorized_services` + `user_credentials` rows for that
  user.
- Admin-side: in Entra → app registration → **API permissions** →
  remove the Microsoft Graph permissions, OR delete the app
  registration entirely. Revokes every active grant.
