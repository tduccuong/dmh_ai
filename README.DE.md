# DMH-AI

Eine leichtgewichtige, selbst gehostete Chat-Oberfläche für Ollama auf Ihrem lokalen Rechner. Läuft vollständig in Docker — kein Node.js, keine Python-Abhängigkeiten.

## Screenshots

![Bildanalyse](image-analysis.png)
![Websuche](web-search.png)

## Funktionen

- **Integrierte Websuche** — wie Perplexity, aber selbst gehostet und privat. DMH-AI erkennt automatisch, wenn Ihre Frage aktuelle Informationen benötigt, durchsucht das Web über eine integrierte SearXNG-Instanz und fasst die Ergebnisse zu einer kohärenten, quellenbasierten Antwort zusammen. Funktioniert in jeder Sprache.
- **Medienanhänge** — Dokumente (PDF, DOCX, XLSX), Bilder und Videos vom Gerät anhängen. Auf dem Handy direkt ein Foto aufnehmen oder ein Video aufzeichnen und in den Chat einfügen — kein Speichern in der Galerie nötig.
- Chat mit jedem Ollama-Modell — Cloud oder lokal — über eine übersichtliche Web-Oberfläche
- Persistente Chat-Sitzungen in SQLite gespeichert
- Automatische Kontextzusammenfassung — endlos chatten ohne Token-Limits
- Markdown-Darstellung für Antworten
- Mehrsprachige Oberfläche: Englisch, Vietnamesisch, Deutsch, Spanisch, Französisch
- Zugriff von jedem Gerät im Netzwerk

## Voraussetzungen

- [Docker](https://docs.docker.com/get-docker/) mit Compose-Plugin
- [Ollama](https://ollama.com/download) lokal auf Port 11434

### Ollama installieren

**Linux:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**Windows:**
Installationsprogramm herunterladen und ausführen von [ollama.com/download](https://ollama.com/download)

Installation überprüfen:
```bash
ollama --version
```

## Schritt 1 — Modelle auswählen

DMH-AI funktioniert mit **Cloud-Modellen** (empfohlen für die meisten Nutzer) und **lokalen Modellen** (wenn Datenschutz oberste Priorität hat). Sie können beide frei kombinieren — im UI einfach umschalten.

---

### Option A: Cloud-Modelle (empfohlen)

**Am besten für die meisten Nutzer.** Ollamas Cloud-Modelle sind schnell, leistungsstark und kostenlos mit großzügigen Limits im Free-Tier. Die Inferenz läuft auf Ollamas Servern und wird über Ihre lokale Ollama-Instanz gestreamt — keine GPU nötig, keine Konfigurationsänderungen in DMH-AI.

**Unsere Top-Empfehlung:**

| Modell | Warum |
|---|---|
| `mistral-large-3:675b-cloud` | Bester Allrounder — schnell, bildtauglich (analysiert Bilder), hervorragend für allgemeinen Chat, Programmierung, logisches Denken und Mehrsprachigkeit |
| `ministral-3:14b-cloud` | Mittlere Größe, guter Allrounder — extrem schnell und ebenfalls bildtauglich |

Weitere empfehlenswerte Cloud-Modelle:

| Modell | Hinweise |
|---|---|
| `qwen3.5:cloud` | Stark in Mehrsprachigkeit und logischem Denken |
| `gemini-3-flash-preview:cloud` | Googles Flaggschiff-Modell, tiefes Reasoning und sehr schnell |

**Einrichtung:**

1. **Kostenloses Ollama-Konto erstellen** auf [ollama.com](https://ollama.com) — klicken Sie auf **Sign Up**.

2. **Lokales Ollama mit Ihrem Konto verbinden:**
   ```bash
   ollama login
   ```
   Ein Browserfenster öffnet sich zur Authentifizierung. Nach dem Login ist Ihre lokale Ollama-Instanz mit Ihrem Konto verknüpft.

3. **Cloud-Modell herunterladen:**
   ```bash
   ollama pull mistral-large-3:675b-cloud
   ```

Das war's. Das Modell erscheint sofort in der DMH-AI-Auswahlliste — auswählen und loschatten.

Cloud-Modelle sind am `:cloud`-Tag erkennbar. Sie benötigen eine Internetverbindung, belasten aber Ihre lokale Hardware nicht.

---

### Option B: Lokale Modelle (vollständig offline, maximaler Datenschutz)

**Am besten wenn Datenschutz oberste Priorität hat.** Alle Daten bleiben auf Ihrem Rechner — nichts verlässt Ihr Netzwerk. Erfordert ausreichend RAM/VRAM für das Modell.

**Text und Dokumente (schnell, wenig Speicher):**

| Modell | Größe | Hinweise |
|---|---|---|
| `gemma3n:e2b` | ~5,6 GB | Bestes kleines mehrsprachiges Allzweck-Modell |
| `phi4-mini:3.8b` | ~2,5 GB | Gutes kleines Allzweck-Modell |
| `granite4:3b` | ~2,1 GB | Starkes Reasoning und schnell |

**Bilder und Vision:**

| Modell | Größe | Hinweise |
|---|---|---|
| `ministral-3:3b` | ~3 GB | Unterstützt Bildeingabe, auch gut für allgemeine Aufgaben und schnell |

**Lokales Modell herunterladen:**
```bash
ollama pull mistral-3:3b
```

Unter Linux Ollama starten, falls nicht bereits als Dienst aktiv:
```bash
ollama serve
```
Unter Windows startet Ollama automatisch — `ollama serve` ist nicht nötig.

## Schritt 2 — Docker installieren

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**Windows:** **Docker Desktop** herunterladen und installieren von [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). Nach der Installation Docker Desktop öffnen und warten, bis das Wal-Symbol in der Taskleiste aufhört zu animieren.

## Schritt 3 — DMH-AI starten

**Linux:**
```bash
./build.sh && ./dist/run.sh
```

**Windows** — in der Eingabeaufforderung:
```
build.bat && dist\run.bat
```

Öffnen Sie [http://localhost:8080](http://localhost:8080) im Browser. Andere Geräte im Netzwerk können über `http://<Ihre-IP-Adresse>:8080` zugreifen.

Für **Spracheingabe** den HTTPS-Endpunkt `https://localhost:8443` (oder `https://<Ihre-IP-Adresse>:8443`) verwenden. Die Warnung zum selbstsignierten Zertifikat einmalig akzeptieren. Auf iOS den Link in der Zertifikatswarnung tippen, um das Zertifikat herunterzuladen und über Einstellungen zu installieren.

Benutzerdaten werden gespeichert in:
- `dist/db/` — SQLite-Chat-Datenbank
- `dist/user_assets/` — Hochgeladene Dateien, nach Sitzung organisiert
- `dist/system_logs/system.log` — Websuche- und System-Protokoll

Zum Umzug auf einen anderen Rechner den gesamten `dist/`-Ordner kopieren — alle Daten sind enthalten.

## Websuche — Ihr eigenes selbst gehostetes Perplexity

DMH-AI enthält eine integrierte Websuche-Pipeline, ähnlich wie Perplexity, ChatGPT Search und Google Gemini — aber vollständig selbst gehostet und privat.

**So funktioniert es:**

1. Sie stellen eine Frage in beliebiger Sprache
2. Das KI-Modell beurteilt, ob Ihre Frage aktuelle Webdaten benötigt (keine fest codierten Schlüsselwörter — es versteht die Absicht)
3. Falls ja, extrahiert DMH-AI Suchbegriffe, fragt die integrierte SearXNG-Suchmaschine ab und ruft die besten Ergebnisse ab
4. Das KI-Modell fasst die Suchergebnisse zu einer kohärenten, gut strukturierten Antwort zusammen, die auf aktuellen Informationen basiert

Alles geschieht automatisch und transparent — Sie stellen einfach Ihre Frage und erhalten eine aktuelle Antwort. Keine API-Schlüssel, keine Abonnements, keine Daten verlassen Ihr Netzwerk (Suchanfragen laufen über Ihre selbst gehostete SearXNG-Instanz).

## Architektur

```
Browser
  ├── nginx :8080 (HTTP)
  └── nginx :8443 (HTTPS, für Spracheingabe)
        ├── /          → index.html (SPA)
        ├── /api       → Ollama :11434
        ├── /sessions  → Python-Backend :3000
        ├── /assets    → Python-Backend :3000
        ├── /search    → Python-Backend :3000 → SearXNG :8888
        └── /log       → Python-Backend :3000
```

Das gesamte Frontend ist eine einzige `code/index.html`-Datei — Vanilla JS, kein Framework, kein Build-Schritt. Das Backend ist `code/backend/server.py` und nutzt ausschließlich die Python-Standardbibliothek.

## Projektstruktur

```
code/
  index.html              # gesamtes Frontend (HTML + CSS + JS)
  backend/server.py       # Sitzungs-API, Datei-Upload, Such-Proxy, Logging
  nginx.conf              # Reverse-Proxy-Konfiguration
  Dockerfile              # nginx:alpine + python3
  start.sh                # Entrypoint: startet Python-Backend dann nginx
  docker-compose.yml      # Compose-Datei
  searxng-settings.yml    # SearXNG-Konfiguration (aktiviert JSON-API auf Port 8888)
  run.sh                  # Linux-Startskript (wird nach dist/ kopiert von build.sh)
  run.bat                 # Windows-Startskript (wird nach dist/ kopiert von build.bat)
build.sh                  # Linux: baut Images und erstellt dist/
build.bat                 # Windows: baut Images und erstellt dist/
dist/                     # erzeugt von build.sh / build.bat — nicht manuell bearbeiten
```
