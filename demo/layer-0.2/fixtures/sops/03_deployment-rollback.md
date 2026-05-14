# SOP: Deployment-Rollback

DMH SME Demo GmbH — Stand: Q2/2026 — Eigentümer: DevOps

## Wann auslösen

- Error-Rate auf `/api/*` > 1 % über 5 Minuten nach einem Release.
- Latenz P95 auf `/api/checkout` > 2 Sekunden nach einem Release.
- Bug-Report mit Datenverlust-Risiko innerhalb der ersten Stunde
  nach Release.

## Schritte für Kubernetes-Deployments

1. **Vorherige Revision identifizieren:**
   ```bash
   kubectl rollout history deployment/dmh-api -n prod
   ```
2. **Rollback ausführen:**
   ```bash
   kubectl rollout undo deployment/dmh-api -n prod
   ```
   Bei Bedarf gezielte Revision via `--to-revision=<N>`.
3. **Status verifizieren:**
   ```bash
   kubectl rollout status deployment/dmh-api -n prod
   ```
4. **Verifikation der Metriken:** Grafana-Dashboard `prod-api-health`
   öffnen — Error-Rate und P95 müssen innerhalb von 3 Minuten auf
   Vor-Release-Niveau zurückkehren.

## Kommunikation

- Slack `#deploys`: Rollback-Grund und Revisions-Nummer posten.
- Wenn Kunden betroffen waren: Status-Seite aktualisieren.
- Post-Mortem-Doc im Notion-Workspace `engineering/postmortems`
  innerhalb von 48 Stunden anlegen.

## Schema-Migrationen

Datenbank-Migrationen werden **niemals** in derselben Deployment
ausgerollt wie inkompatibler Code. Wenn das Rollback eine
DB-Migration umkehren muss, ist es kein Routine-Rollback —
Eskalation gemäß `01_eskalation-matrix.md` Sev1.
