# DMH-AI

Eine selbst gehostete KI-Chat-App, die auf Ihrem Computer läuft — wie ChatGPT, aber privat, kostenlos und ganz Ihnen gehörend.

Da DMH-AI auf Ihrem eigenen Rechner läuft, **haben Sie die vollständige Kontrolle über Ihre Daten**. Gespräche, Begleitergedächtnis, Dateien — alles verbleibt auf Ihrer Hardware, in Ihrem Zuhause. Kein Dritter kann darauf zugreifen, es analysieren oder verwerten. Bei Cloud-KI wird nur der Text jeder Anfrage zur Verarbeitung gesendet — nichts anderes verlässt Ihren Rechner.

## Screenshots

![Automatische Websuche](auto_web_search.png)
*Bei zeitkritischen Fragen durchsucht DMH-AI automatisch das Web, ruft aktuelle Daten ab und liefert eine belegte Antwort.*

---

![Bilder ansehen](see_images.png)
*Beliebiges Foto oder Video einfügen und Fragen dazu stellen.*

---

## Zwei Modi: Vertrauter und Assistent

DMH-AI bietet zwei Arten von KI-Sitzungen, umschaltbar über die obere Leiste.

### Vertrauter (Confidant) — Ihr privater KI-Begleiter

Der Vertraute ist gesprächsorientiert, wie ChatGPT. Sie schreiben eine Nachricht, die KI antwortet, und der Austausch fließt natürlich hin und her. Das ist der Modus für alltägliche Fragen, Schreibhilfe, Bildanalyse, Brainstorming — immer dann, wenn Sie eine unmittelbare, gestreamte Antwort möchten.

Was den Vertrauten zu mehr als einem Chat-Werkzeug macht:

- **Er wächst mit Ihnen.** Der Vertraute baut im Laufe der Zeit ein Profil von Ihnen auf — Vorlieben, Kontext, was Sie ihm erzählt haben — und nutzt dieses Wissen, um relevantere und persönlichere Antworten zu geben. Sie müssen sich nie wiederholen.
- **Er erinnert sich an lange Gespräche.** Egal wie lange eine Sitzung dauert, der Vertraute komprimiert alten Kontext intelligent, sodass Sie nie an Speichergrenzen stoßen.
- **Er sucht automatisch im Web.** Stellen Sie eine Frage zu aktuellen Ereignissen und der Vertraute entscheidet selbst, ob eine Websuche nötig ist. Falls ja, ruft er Liveresultate über die integrierte Suchmaschine ab und fasst sie zu einer belegten Antwort zusammen — ohne dass Sie darum bitten müssen.
- **Ihr Profil bleibt auf Ihrem Rechner.** Beliebte KI-Chatbots bauen ebenfalls ein Bild von Ihnen auf, speichern es jedoch auf ihren Servern außerhalb Ihrer Kontrolle. Alles, was der Vertraute über Sie lernt, verbleibt auf Ihrer Hardware. Sie können es jederzeit in den Gesprächseinstellungen einsehen oder löschen.

### Assistent (Assistant) — KI, die im Hintergrund arbeitet, während Sie chatten

Der Assistent ist für zeitaufwendige Aufgaben gedacht: Recherchen, lange Dokumente schreiben, Code ausführen, mehrstufige Abläufe koordinieren. Sie geben ihm ein Ziel, er arbeitet autonom im Hintergrund und benachrichtigt Sie, wenn er fertig ist — Sie müssen nicht warten oder zusehen.

Während der Assistent arbeitet, können Sie weiter chatten. Fragen Sie nach dem Fortschritt und Sie erhalten ein Echtzeit-Update. Wenn der Assistent fertig ist, erscheint das Ergebnis in der Sitzung und eine Benachrichtigung erscheint.

Assistent-Sitzungen sind voneinander unabhängig: Sie können mehrere gleichzeitig laufen lassen, jede an einem anderen Ziel.

**Wann was verwenden:**

| | Vertrauter | Assistent |
|---|---|---|
| Antwort-Stil | Gestreamt, sofort | Benachrichtigung bei Fertigstellung |
| Geeignet für | Fragen, Schreiben, Bildanalyse, Gespräch | Lange Aufgaben, Recherche, mehrstufige Arbeit |
| Müssen Sie warten? | Ja, aber nur Sekunden | Nein — chatten Sie weiter |
| Mehrere gleichzeitig | Eine aktive Sitzung | Viele gleichzeitig |

---

## Was Sie bekommen

- **Begleitergedächtnis** — personalisierte Antworten, die mit der Zeit besser werden
- **Integrierte Websuche** — wie Perplexity, aber selbst gehostet und privat; funktioniert in jeder Sprache
- **Medienanhänge** — PDF, DOCX, XLSX, Bilder und Videos; auf dem Handy direkt ins Chat fotografieren oder aufnehmen
- **Mehrbenutzerunterstützung** — jede Person hat eigene Anmeldedaten, eigene Verläufe und eigene Dateien; Admin verwaltet Nutzer direkt in der App
- **Persistenter Chat-Verlauf** — alle Sitzungen gespeichert und durchsuchbar
- **Mehrsprachige Oberfläche** — Englisch, Vietnamesisch, Deutsch, Spanisch, Französisch
- **Zugriff von jedem Gerät im Heimnetzwerk** — Smartphone, Tablet, Laptop

Eine ausführliche technische Beschreibung finden Sie in [specs/architecture.md](specs/architecture.md).

---

## Installation

### Schritt 1 — Docker installieren

Docker führt DMH-AI in einem eigenständigen Container aus.

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**macOS / Windows:** Laden Sie **Docker Desktop** herunter und führen Sie es aus: [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). Nach der Installation öffnen Sie Docker Desktop und warten Sie, bis das Wal-Symbol in der Menüleiste (macOS) bzw. Taskleiste (Windows) aufhört zu animieren — dann ist es bereit.

### Schritt 2 — DMH-AI bauen und installieren

**Linux / macOS:**
```bash
./build.sh        # Docker-Image bauen und dist/ zusammenstellen
./install.sh      # nach ~/.dmhai/ installieren und dmhai-Befehl registrieren
dmhai start       # App starten
```

**Windows** — Eingabeaufforderung öffnen und ausführen:
```
build.bat
install.bat
dmhai start
```

Öffnen Sie [http://localhost:8080](http://localhost:8080) im Browser.

### App verwalten

```bash
dmhai start      # starten
dmhai stop       # stoppen
dmhai restart    # neu starten (nimmt neuen Build automatisch auf)
dmhai status     # laufende Container anzeigen
```

Nach einer Code-Aktualisierung neu bauen und neu installieren:
```bash
./build.sh --no-export   # Image neu bauen ohne Tars zu exportieren (schneller)
./install.sh             # installierte Konfiguration aktualisieren; Benutzerdaten bleiben erhalten
dmhai restart
```

Unter Windows `build.bat` und `install.bat` verwenden.

### Erste Anmeldung

Beim ersten Start erstellt DMH-AI automatisch ein Standard-Admin-Konto:

| Benutzername | Passwort |
|---|---|
| `admin` | `dmhai` |

Anmelden, dann **sofort das Passwort ändern**: Benutzersymbol (oben rechts) → **Passwort ändern**.

---

## KI-Dienst verbinden (Admin)

DMH-AI benötigt ein KI-Backend. Der Admin konfiguriert dies einmalig in den Einstellungen. Nutzer wählen kein Modell aus.

### Standard — Ollama Cloud

Ollama bietet leistungsstarke Cloud-KI-Modelle kostenlos an, mit großzügigen Nutzungslimits. Dies ist der einfachste Einstieg: kein GPU, keine besonderen Hardwareanforderungen.

1. Gehen Sie zu [ollama.com](https://ollama.com) und erstellen Sie ein kostenloses Konto
2. Profilbild → **Settings** → **API Keys** → **Create new key**, Schlüssel kopieren
3. In DMH-AI: Benutzersymbol → **Einstellungen** → **Ollama Cloud — API-Konten** → **Konto hinzufügen**, Schlüssel einfügen

Das war's. Beide Modi — Vertrauter und Assistent — stehen allen Nutzern sofort zur Verfügung.

Bei diesem Setup wird nur der Text jeder KI-Anfrage zur Verarbeitung an Ollamas Server gesendet. Alle Nutzerdaten — Chat-Verlauf, Begleitergedächtnis, hochgeladene Dateien — verbleiben auf Ihrem Rechner und werden niemals an Dritte weitergegeben.

### Alternative — Lokales Ollama (vollständig offline)

Für ein Setup, bei dem absolut nichts das Netzwerk verlässt — nicht einmal KI-Anfragen — kann auf eine lokal laufende Ollama-Instanz umgestellt werden. Dies erfordert Hardware, die KI-Modelle ausführen kann (ein moderner CPU reicht für kleine Modelle; eine GPU beschleunigt größere Modelle erheblich).

**Ollama installieren:**

```bash
# Linux
curl -fsSL https://ollama.com/install.sh | sh
```

macOS / Windows: Installationsprogramm herunterladen von [ollama.com/download](https://ollama.com/download). Ollama startet nach der Installation automatisch.

**Modell herunterladen** (Admin entscheidet, welches Modell verwendet wird):
```bash
ollama pull <modell-name>
```

Unter Linux Ollama starten, falls nicht bereits als Dienst aktiv:
```bash
ollama serve
```

In den DMH-AI-Admineinstellungen die **Ollama Local — Endpunkt-URL** auf die Ollama-Instanz zeigen (z. B. `http://localhost:11434`) und die KI-Modelle auf lokale Modellnamen umstellen.

---

## Zugriff von anderen Geräten im Netzwerk

Sobald DMH-AI läuft, kann jedes Smartphone, Tablet oder Laptop im selben WLAN es nutzen.

Finden Sie die lokale IP-Adresse Ihres Rechners (z. B. `192.168.1.10`) und öffnen Sie `http://192.168.1.10:8080` auf einem beliebigen Gerät.

**Spracheingabe** erfordert HTTPS. Verwenden Sie `https://<Ihre-IP>:8443`. Der Browser zeigt eine Sicherheitswarnung wegen des selbstsignierten Zertifikats — das ist erwartet, einmalig akzeptieren. Auf iOS den Link in der Zertifikatswarnung tippen, um das Zertifikat herunterzuladen und über Einstellungen zu installieren (einmalig pro Gerät).

---

## Admin-Einstellungen Referenz

Benutzersymbol → **Einstellungen** (nur Admins).

**Ollama Cloud — API-Konten**

Ein oder mehrere Konten (Bezeichnung + API-Schlüssel) hinzufügen. DMH-AI wechselt automatisch zwischen allen hinzugefügten Konten — wenn eines sein Ratenlimit erreicht, übernimmt das nächste nahtlos.

**Beispiel:** Eine vierköpfige Familie legt je ein kostenloses Ollama-Konto an und trägt alle vier Schlüssel hier ein. DMH-AI verteilt die Last automatisch und transparent — kein Familienmitglied muss sich darum kümmern, welches Konto gerade genutzt wird oder ob ein Limit erreicht wurde.

**KI-Modelle**

Konfigurieren Sie, welches KI-Modell welche Rolle übernimmt: Vertrauter-Gespräche, Assistent-Hintergrundarbeit, Websuche, Bild- und Videoanalyse sowie Kontextkomprimierung. Jede Rolle kann ein anderes, für die jeweilige Aufgabe optimiertes Modell verwenden.

**Ollama Local — Endpunkt-URL**

Standardmäßig verbindet sich DMH-AI mit Ollama unter `http://localhost:11434`. Ändern Sie dies, wenn Ollama auf einem anderen Rechner in Ihrem Netzwerk läuft (z. B. einem Heimserver).

---

## Websuche

DMH-AI enthält eine integrierte Websuche-Pipeline — ähnlich wie Perplexity oder ChatGPT Search, aber selbst gehostet und privat.

**Wie es funktioniert:**

1. Sie stellen eine Frage in beliebiger Sprache
2. Die KI entscheidet, ob Ihre Frage aktuelle Informationen aus dem Web benötigt (keine fest codierten Schlüsselwörter — sie versteht die Absicht)
3. Falls ja, sucht DMH-AI über die integrierte SearXNG-Instanz und ruft die besten Ergebnisse ab
4. Die KI fasst die Ergebnisse zu einer kohärenten, gut strukturierten Antwort zusammen

Sie müssen nichts anders machen — stellen Sie einfach Ihre Frage. Suchanfragen laufen über Ihre eigene SearXNG-Instanz, nicht über Drittanbieter-Dienste.

---

## Ihre Daten

Nach dem Ausführen von `install.sh` werden alle Live-Daten in `~/.dmhai/` gespeichert:

- `~/.dmhai/db/` — Chat-Verlauf (SQLite-Datenbank)
- `~/.dmhai/user_assets/` — hochgeladene Dateien, nach Sitzung organisiert
- `~/.dmhai/system_logs/system.log` — Websuche- und System-Protokoll

`install.sh` erneut auszuführen ist sicher — vorhandene Datendateien werden nie überschrieben. Jede Datei wird nur dann aus `dist/` kopiert, wenn sie in `~/.dmhai/` noch nicht vorhanden ist.

Zum Sichern oder Übertragen auf einen anderen Rechner kopieren Sie `~/.dmhai/` und führen Sie `install.sh` auf dem neuen Rechner aus.

Weitere Nutzer hinzufügen: Benutzersymbol → **Benutzer verwalten**.
