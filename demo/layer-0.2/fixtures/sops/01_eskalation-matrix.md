# SOP: Eskalation bei Produktionsstörungen

DMH SME Demo GmbH — Stand: Q2/2026 — Eigentümer: Ops-Team

## Severity-Stufen

| Stufe | Beispiel                                              | Erste Reaktion      |
|-------|-------------------------------------------------------|---------------------|
| Sev1  | Datenbank vollständig ausgefallen, Zahlungsabwicklung tot | Sofort, On-Call wecken |
| Sev2  | Antwortzeiten > 5 s, einzelne Endpunkte 5xx           | Innerhalb 30 Minuten |
| Sev3  | Kosmetischer UI-Fehler, einzelner Kundenreport falsch | Nächster Arbeitstag |

## Sev1 — kritischer Ausfall (z. B. Datenbankausfall, Payment-Provider tot)

1. **Sofort:** On-Call-Engineer wecken über PagerDuty (Service:
   `dmh-prod-sev1`). PagerDuty ruft das diensthabende Mitglied an,
   wenn nach 90 Sekunden keine Annahme erfolgt rotiert der Anruf
   zur Sekundär-Schicht.
2. **Innerhalb 15 Minuten:** CTO über Slack-Channel
   `#sev1-incidents` benachrichtigen und einen Incident-Bridge
   eröffnen (Google Meet, Link aus Channel-Topic).
3. **Innerhalb 30 Minuten:** Wenn keine Antwort von CTO,
   Geschäftsführung (CEO) direkt anrufen (Notfall-Nummer im
   geschützten 1Password-Vault `runtime-emergency`).
4. **Kundenkommunikation:** Status-Seite auf
   `status.dmh-demo.example` innerhalb von 20 Minuten aktualisieren.
   Kommunikationsmuster siehe SOP `04_kunden-kommunikation.md`.

## Sev2 — degradierter Service

1. Ticket in Linear-Project `OPS` öffnen, Label `sev2`.
2. Lead-Engineer per Slack-DM benachrichtigen — keine Telefon-Eskalation.
3. Behebung innerhalb der nächsten Geschäftsstunden.

## Sev3 — kosmetisch / nicht-blockierend

1. Ticket in Linear-Project `OPS`, Label `sev3`.
2. Reguläre Triage im Daily-Standup.
