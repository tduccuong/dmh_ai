# SOP: Secret-Rotation (vierteljährlich)

DMH SME Demo GmbH — Stand: Q2/2026 — Eigentümer: Security-Team

## Kadenz

Alle produktiven Geheimnisse werden vierteljährlich rotiert
(zum ersten Werktag eines neuen Quartals). Außerplanmäßige
Rotationen erfolgen sofort bei jedem Verdacht auf Kompromittierung.

## Umfang

Folgende Klassen werden rotiert:

- API-Schlüssel zu externen SaaS-Anbietern (Stripe, SendGrid,
  Twilio, OpenAI). Stripe-Schlüssel sind ein Sonderfall — siehe
  unten.
- OAuth-Client-Secrets für die eigenen Login-Flows.
- Datenbank-Passwörter für alle Service-Accounts. Master-DB-Passwort
  nur alle 12 Monate oder bei Verdacht.
- SSH-Schlüssel für CI-Runner.

## Schritte (Standard-Fall)

1. **Neuen Wert generieren** im jeweiligen Provider-Portal oder
   per `openssl rand -hex 32` für eigene Secrets.
2. **Im 1Password-Vault `prod-secrets`** das alte Item duplizieren,
   neuen Wert hinterlegen, mit Label `pending-rotation-<date>`
   markieren.
3. **In Kubernetes-Secrets** parallel ausrollen:
   ```bash
   kubectl create secret generic <name> --from-literal=KEY=<new> \
     -n prod --dry-run=client -o yaml | kubectl apply -f -
   kubectl rollout restart deployment/<service> -n prod
   ```
4. **Verifikation:** Service-Logs auf Auth-Fehler prüfen
   (15-Minuten-Fenster nach Restart).
5. **Altes Secret im Provider widerrufen.** Erst nach
   erfolgreicher Verifikation — nicht vorher.
6. **Audit-Log-Eintrag** in Notion `security/rotations` mit
   Datum, durchführender Person, betroffenen Services.

## Sonderfall Stripe

Stripe-Live-Schlüssel niemals direkt löschen. Stattdessen:
neuen Schlüssel anlegen, im Code als `STRIPE_SECRET_KEY_NEXT`
parallel deployen, nach 48 Stunden Validation den alten
Schlüssel widerrufen. Bei jedem Stripe-Rotationsschritt muss
ein zweites Security-Team-Mitglied gegenzeichnen (Vier-Augen-Prinzip).
