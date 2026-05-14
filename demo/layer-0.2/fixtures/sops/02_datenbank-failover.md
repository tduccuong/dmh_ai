# SOP: Datenbank-Failover (Primary → Replica)

DMH SME Demo GmbH — Stand: Q2/2026 — Eigentümer: Plattform-Team

## Wann auslösen

- Primary-Datenbank antwortet nicht mehr auf Health-Checks (3
  aufeinanderfolgende Fehler innerhalb von 90 Sekunden).
- Primary ist erreichbar, aber Replication-Lag > 60 Sekunden und
  steigend.
- Geplante Wartung der Primary-Infrastruktur (z. B. Storage-Upgrade).

**Nicht ausführen** ohne Eskalation an Lead-Engineer (per Slack-DM),
außer es liegt ein bestätigter Sev1-Vorfall vor.

## Voraussetzungen

- Zugriff auf den Bastion-Host `bastion.prod.dmh-demo.example`.
- AWS-Profile `dmh-prod-ops` aktiv.
- Replica `replica-eu-west-1b` muss aktuell sein
  (`SELECT pg_last_wal_replay_lsn();` vs Primary). Lag < 5 Sekunden
  ist Voraussetzung — sonst Datenverlust.

## Schritte

1. **Read-Only-Modus auf der Primary erzwingen:**
   ```bash
   psql -h primary.prod.dmh-demo.example -U ops -c \
     "ALTER SYSTEM SET default_transaction_read_only TO on; SELECT pg_reload_conf();"
   ```
2. **Replica zur Primary befördern:**
   ```bash
   aws rds promote-read-replica --db-instance-identifier replica-eu-west-1b
   ```
3. **DNS-Eintrag umlegen:** Route53-Record `db.prod.dmh-demo.example`
   auf die neue Primary zeigen lassen (TTL 30 s, daher Propagation
   ≤ 1 Minute).
4. **Connection-Pooler durchstarten:** PgBouncer per
   `kubectl rollout restart deploy/pgbouncer` neu starten, damit
   alte Verbindungen zur abgesetzten Primary aufgegeben werden.
5. **Smoke-Test:** Healthcheck-Endpunkt `/_internal/db/ping` muss
   200 zurückgeben.

## Rollback

Falls nach Schritt 2 unerwartete Inkonsistenzen auftreten:
Replica nicht mehr befördern, sondern alten Primary nach
Reparatur erneut zur Primary machen (separate SOP
`02b_rollback-failover.md`, in diesem Demo-Set nicht enthalten).
