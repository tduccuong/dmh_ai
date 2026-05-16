# Google Cloud OAuth setup for DMH-AI's Google Workspace connector

One-page checklist for the admin who wants to switch DMH-AI from
the mock vendor MCP (deterministic, demo-friendly) to real Google
Workspace (production / live UAT). 10–15 minutes of clicks in
Google Cloud Console plus pasting the result into DMH-AI's admin
UI.

## Pre-requisites

- A Google Cloud account with billing enabled (free tier is
  enough for OAuth client + API quotas).
- An organisation Google Workspace tenant (employees' email
  addresses you want the connector to act on behalf of). You can
  test with a personal `@gmail.com` account too — works the same.
- DMH-AI stage URL is known (e.g. `https://stage.your-company.example`
  or `http://127.0.0.1:8080` for local). The OAuth callback path
  is fixed at `/oauth/callback`.

## Steps

### 1. Create / pick a Google Cloud project

1. Open **<https://console.cloud.google.com/>**.
2. Pick an existing project from the top selector OR click
   **New Project** → name it (e.g. *"DMH-AI Connectors"*).

### 2. Enable the three APIs

Each of the GW connector's 6 functions lives in one of three APIs.
Enable all three:

1. **Gmail API** — <https://console.cloud.google.com/apis/library/gmail.googleapis.com>
2. **Calendar API** — <https://console.cloud.google.com/apis/library/calendar-json.googleapis.com>
3. **Drive API** — <https://console.cloud.google.com/apis/library/drive.googleapis.com>

Click **Enable** on each. Wait ~30 seconds per API for activation.

### 3. Configure the OAuth consent screen (one-time per project)

1. **APIs & Services → OAuth consent screen**.
2. **User Type**: pick **Internal** if your project is inside a
   Google Workspace org and only your org's employees will use
   it; **External** if you want personal `@gmail.com` accounts to
   work too.
3. Fill: App name (*"DMH-AI Connector"*), User support email
   (your address), Developer contact (your address). Skip
   everything else for now.
4. **Scopes** — click **Add or Remove Scopes** and add (paste
   each, click "ADD TO TABLE"):
   ```
   https://www.googleapis.com/auth/gmail.readonly
   https://www.googleapis.com/auth/gmail.send
   https://www.googleapis.com/auth/calendar.readonly
   https://www.googleapis.com/auth/calendar.events
   https://www.googleapis.com/auth/drive.readonly
   https://www.googleapis.com/auth/drive.file
   ```
5. **Test users** — for **External** type only: add the email
   addresses of the people you'll test with (yourself + a sales
   colleague). Internal type skips this.
6. Save and exit.

### 4. Create the OAuth 2.0 Client

1. **APIs & Services → Credentials**.
2. Click **Create Credentials → OAuth client ID**.
3. **Application type**: **Web application**.
4. **Name**: *"DMH-AI Stage"* (or distinguishing label per
   deployment).
5. **Authorized redirect URIs** — click **+ ADD URI** and paste
   the DMH-AI callback URL for this deployment. The URI must
   match EXACTLY what DMH-AI sends — host, port, path, scheme:
   ```
   http://localhost:8080/oauth/callback
   ```
   (This is what the local stage sends by default — built from
   `AgentSettings.oauth_redirect_base_url`. For production at a
   real domain, use `https://<your-dmh-ai-host>/oauth/callback`
   AND update the AgentSettings row so the BE emits the same URI.)
   Google's OAuth treats `localhost` and `127.0.0.1` as different
   strings — use `localhost` here to match the default.
6. Click **Create**.
7. Google shows a modal with **Client ID** and **Client secret**
   — **copy both immediately**. The secret is only fully visible
   here; you can re-download a JSON later but it's faster to
   copy now.

### 5. Paste the credentials into DMH-AI

1. Open DMH-AI in the browser, log in as the admin
   (`admin@…`).
2. Click the user-menu icon → **External Connectors** (or
   navigate directly to `/connectors`). The page is a full-page
   master-detail view — left sidebar lists every connector, right
   pane shows the selected one's config form.
3. Click **Google Workspace** in the sidebar.
4. Paste **Client ID** + **Client Secret** into the matching
   fields. (Note: existing values aren't echoed back for
   security; the placeholder reads "(saved — paste new to
   replace)" when a credential is already on file.)
5. **MCP URL** — leave as the default if running the in-process
   MCPServer (it's pre-seeded to
   `http://127.0.0.1:8087/google_workspace`). Override only if
   you're pointing at an external Google MCP endpoint.
6. Tick **Enabled** if not already.
7. Click **Save**.
8. Click **Test connection**. Expected: ✅ "Reachable — 6 functions
   exposed by dmh-ai-mcp-google_workspace." If you see a
   network error, double-check the MCP URL field — the
   in-process REST translator runs at the pre-filled default
   (`http://127.0.0.1:8087/google_workspace`); production-only
   installs that point at Google's hosted MCP URL need that URL
   pasted in correctly.

### 6. Sales staff connects their own Google account

1. Sales staff logs in to DMH-AI as their employee account.
2. Clicks the user-menu icon → **My Services**.
3. In the **Available** list, clicks **Connect Google Workspace**.
4. Browser redirects to Google's consent screen — they see the
   six scope descriptions ("Read your Gmail messages", "Send
   email on your behalf", "Manage your calendar events", "Read
   your Drive files", "Upload files to Drive").
5. Approve.
6. Browser redirects back to DMH-AI. They see "Connected as
   <their email>".
7. Open assistant-mode chat and ask one of the demo scenarios.

## Common errors

| Symptom | Likely cause |
|---|---|
| Google shows "Access blocked: This app's request is invalid" | Redirect URI in step 4.5 doesn't match the stage host. Add the right URI to the OAuth client (you can add multiple). |
| Google shows "Error 403: access_denied" | App is in **Testing** mode and the user isn't on the **Test users** list (step 3.5). Add them, or publish the app for prod. |
| After consent, browser redirects to `/oauth/callback` with `error=access_denied` | User clicked "Cancel" on the consent screen. Try again. |
| Chat reply says "missing_credentials" | OAuth flow didn't complete — check `user_credentials` table on master via `dmh_ai rpc`. Should have one row at `target='oauth:google_workspace'`. |
| Chat reply says "Vendor error: unauthorised" | Token expired or scope mismatch. Disconnect (FE button) and re-connect. |
| All chat replies say "Vendor error: rate_limited" | Project's quota exceeded (Gmail's default is generous; rare). Wait or request a quota raise in Cloud Console. |

## Rotating credentials

To rotate the OAuth client secret (e.g. quarterly):

1. In Cloud Console → Credentials → click your OAuth client
   → **Reset secret**.
2. Copy the new secret.
3. In DMH-AI's **External Connectors** page → click the
   **Google Workspace** card → paste the new secret in **Client
   Secret** (leave **Client ID** blank to keep the existing one)
   → **Save**.
4. Click **Test connection** to confirm.

All connected users keep working — only the client-secret-based
token refresh path uses the new secret on its next refresh
(they're cached by the OAuth library).

## Decommissioning

To stop allowing DMH-AI to act on a user's Google account:

- User-side: **My Services** → **Disconnect Google Workspace**.
  Drops `authorized_services` + `user_credentials` rows for that
  user.
- Admin-side: in Cloud Console → **OAuth consent screen** → set
  to **Production** with no `Allowed users`, OR delete the OAuth
  client. Revokes every active grant.
