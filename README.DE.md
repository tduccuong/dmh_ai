# DMH-AI

Eine selbst gehostete KI-Chat-App, die auf Ihrem Computer läuft — wie ChatGPT, aber privat, kostenlos und ganz Ihnen gehörend.

DMH-AI ist mehr als ein Chat-Werkzeug. Es ist ein langlebiger KI-Begleiter, der mit Ihnen wächst — je mehr Sie mit ihm sprechen, desto besser versteht es Sie, und desto mehr wird es zu einem Begleiter, auf den Sie sich wirklich verlassen können.

Da DMH-AI auf Ihrem eigenen Rechner läuft, **haben Sie die vollständige Kontrolle über Ihre Daten**. Gespräche, Nutzerprofil, Dateien — alles verbleibt auf Ihrer Hardware, in Ihrem Zuhause. Kein Dritter kann darauf zugreifen, es analysieren oder verwerten. Wenn Sie lokale Modelle nutzen (Weg B), verlässt kein einziges Byte Ihrer Anfragen oder persönlichen Daten Ihr Netzwerk — das macht DMH-AI zu einem der privatesten KI-Setups, die Sie heute betreiben können.

**Für wen ist das?**

- **Cloud-Nutzer** — Sie möchten schnelles, leistungsstarkes KI-Chatten ohne Sorgen um Nutzungslimits. Sie brauchen keinen leistungsstarken Computer. Sie nutzen Ollamas Cloud-Modelle über Ihren eigenen API-Schlüssel — DMH-AI übernimmt automatisch die Kontoverwaltung und Ratenlimit-Umgehung im Hintergrund, ohne dass Sie sich darum kümmern müssen.
- **Datenschutz-Nutzer** — Sie möchten, dass alles auf Ihrem eigenen Rechner bleibt, vollständig offline. Nichts verlässt jemals Ihr Netzwerk.

Beide Modi funktionieren in derselben App. Sie können jederzeit frei wechseln.

## Screenshots

![Vorgeladene Modelle](preloaded_models.png)
*Drei sofort einsatzbereite Cloud-Modelle — Schlagfertig, Lexicon, Tiefdenker — erscheinen, sobald ein API-Schlüssel hinzugefügt wird. Keine weitere Einrichtung nötig.*

---

![Automatische Websuche](auto_web_search.png)
*Bei zeitkritischen Fragen durchsucht DMH-AI automatisch das Web, ruft aktuelle Daten ab und liefert eine belegte Antwort.*

---

![Bilder ansehen](see_images.png)
*Beliebiges Foto oder Video einfügen und Fragen dazu stellen.*

## Was Sie bekommen

- **Begleitergedächtnis** — DMH-AI lernt Sie mit der Zeit kennen und nutzt dieses Wissen, um relevantere und persönlichere Antworten zu geben — damit Sie sich nie wiederholen müssen. Was DMH-AI von beliebten Chatbots wie ChatGPT oder Gemini unterscheidet: Ihr Profil verlässt niemals Ihren Rechner. Beliebte KI-Chatbots bauen ebenfalls ein Bild von Ihnen auf, speichern es jedoch auf ihren Servern, außerhalb Ihrer Kontrolle, und nutzen es nach eigenem Ermessen. Hier bleibt alles auf Ihrer Hardware. Was DMH-AI über Sie weiß, können Sie jederzeit in den Gesprächseinstellungen einsehen oder löschen.
- **Integrierte Websuche** — wie Perplexity, aber selbst gehostet und privat. Stellen Sie eine Frage und DMH-AI entscheidet selbst, ob eine Websuche nötig ist. Falls ja, werden live Ergebnisse über die integrierte Suchmaschine abgerufen und zu einer quellenbasierten, aktuellen Antwort zusammengefasst. Funktioniert in jeder Sprache.
- **Medienanhänge** — Dokumente (PDF, DOCX, XLSX), Bilder und Videos anhängen. Auf dem Handy ein Foto aufnehmen oder ein Video direkt aufzeichnen und in den Chat einfügen — kein Speichern in der Galerie nötig.
- **Mehrbenutzerunterstützung** — jede Person hat eigene Anmeldedaten, eigene Chat-Verläufe und eigene Dateien. Ein Admin-Konto wird beim ersten Start automatisch erstellt. Admins können Nutzer direkt in der App hinzufügen und entfernen.
- **Persistenter Chat-Verlauf** — alle Unterhaltungen werden gespeichert und sind durchsuchbar.
- **Rollierender Kontext** — chatten Sie so lange Sie möchten, ohne an KI-Speichergrenzen zu stoßen.
- **Mehrsprachige Oberfläche** — Englisch, Vietnamesisch, Deutsch, Spanisch, Französisch.
- **Zugriff von jedem Gerät im Heimnetzwerk** — Smartphone, Tablet, Laptop.

---

## Schnellstart

Es gibt zwei Wege. Wählen Sie den für Sie passenden.

| | Weg A: Cloud | Weg B: Lokal |
|---|---|---|
| **Am besten für** | Die meisten Nutzer | Datenschutz-Nutzer |
| **GPU erforderlich?** | Nein | Je nach Modellgröße |
| **Internet nötig?** | Ja (für KI-Antworten) | Nein |
| **Verlassen Daten das Gerät?** | KI-Anfragen gehen an Ollama-Server | Niemals |
| **Einrichtungszeit** | ~5 Minuten | ~10 Minuten |

---

## Schritt 1 — Docker installieren

Docker führt DMH-AI in einem eigenständigen Container aus. Für beide Wege erforderlich.

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**macOS / Windows:** Laden Sie **Docker Desktop** herunter und führen Sie es aus: [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). Nach der Installation öffnen Sie Docker Desktop und warten Sie, bis das Wal-Symbol in der Menüleiste (macOS) bzw. Taskleiste (Windows) aufhört zu animieren — dann ist es bereit.

## Schritt 2 — DMH-AI bauen und installieren

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

### App verwalten (Linux / macOS)

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

### App verwalten (Windows)

```
dmhai start      # starten
dmhai stop       # stoppen
dmhai restart    # neu starten (nimmt neuen Build automatisch auf)
dmhai status     # laufende Container anzeigen
```

Nach einer Code-Aktualisierung neu bauen und neu installieren:
```
build.bat
install.bat
dmhai restart
```

### Erste Anmeldung

Beim ersten Start erstellt DMH-AI automatisch ein Standard-Admin-Konto:

| Benutzername | Passwort |
|---|---|
| `admin` | `dmhai` |

Anmelden, dann **sofort das Passwort ändern**: Benutzersymbol (oben rechts) → **Passwort ändern**.

---

## Weg A: Cloud-Modelle (für die meisten Nutzer empfohlen)

Ollama bietet leistungsstarke Cloud-KI-Modelle kostenlos an, mit großzügigen Nutzungslimits. Ihre Fragen werden zur Verarbeitung an Ollamas Server gesendet — schnell, kein GPU nötig, keine Abonnementgebühr.

### Ollama API-Schlüssel erstellen

Sie benötigen einen API-Schlüssel für Cloud-Modelle. Kostenlos.

1. Gehen Sie zu [ollama.com](https://ollama.com) und erstellen Sie ein kostenloses Konto (auf **Sign Up** klicken)
2. Klicken Sie auf Ihr Profilbild (oben rechts) → **Settings** → **API Keys**
3. Klicken Sie auf **Create new key**, geben Sie einen beliebigen Namen an und kopieren Sie den Schlüssel an einen sicheren Ort

### API-Schlüssel in DMH-AI hinzufügen

1. Benutzersymbol → **Einstellungen**
2. Unter **Ollama Cloud — API-Konten** auf **Konto hinzufügen** klicken
3. Einen beliebigen Namen eingeben (z. B. "mein Konto") und den kopierten API-Schlüssel einfügen
4. Auf **Speichern** klicken

Das war's. Drei empfohlene Modelle erscheinen sofort oben in der Modellauswahl — einfach eines auswählen und loschatten.

**Empfohlene Modelle (sofort nutzbar, keine weitere Einrichtung):**

- 👁 **Schlagfertig** — schnelle Reaktionen für alltägliche Fragen
- ✍ **Lexicon** — hervorragend beim Schreiben: E-Mails, Essays, Literatur, kreative Texte
- 💡 **Tiefdenker** — langsamer, aber gründlicher; ideal für komplexe Fragen und Bildanalyse
- 🧮 **Mathe-Meister** — optimiert für Mathematik, Logik und Schlussfolgerungen

---

## Weg B: Lokale Modelle (vollständig offline, maximaler Datenschutz)

Alles läuft auf Ihrem Rechner. Für KI kein Internet nötig. Ihre Daten verlassen niemals Ihr Netzwerk.

### Ollama installieren

Ollama führt das KI-Modell lokal auf Ihrem Computer aus.

**Linux:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**macOS / Windows:** Installationsprogramm herunterladen und ausführen von [ollama.com/download](https://ollama.com/download). Ollama startet nach der Installation automatisch im Hintergrund.

Installation überprüfen:
```bash
ollama --version
```

### Ein Modell herunterladen

Wählen Sie ein Modell basierend auf den Möglichkeiten Ihres Computers. Die angegebene Größe ist der benötigte Festplatten- und RAM-Speicher.

**Gute Ausgangspunkte (Text und Dokumente):**

| Modell | Größe | Hinweise |
|---|---|---|
| `gemma3n:e2b` | ~5,6 GB | Bestes kleines mehrsprachiges Modell |
| `phi4-mini:3.8b` | ~2,5 GB | Guter Allrounder, wenig Speicher |
| `granite4:3b` | ~2,1 GB | Schnell, starkes Reasoning |

**Für Bildanalyse:**

| Modell | Größe | Hinweise |
|---|---|---|
| `ministral-3:3b` | ~3 GB | Unterstützt Bildeingabe, schnell |

Gewähltes Modell herunterladen (Beispiel):
```bash
ollama pull gemma3n:e2b
```

Unter Linux Ollama starten, falls nicht bereits als Dienst aktiv:
```bash
ollama serve
```
Unter macOS und Windows startet Ollama automatisch — `ollama serve` ist nicht nötig.

Ihre lokal laufenden Modelle erscheinen in der Modellauswahl. Eines auswählen und loschatten.

---

## Zugriff von anderen Geräten im Netzwerk

Sobald DMH-AI läuft, kann jedes Smartphone, Tablet oder Laptop im selben WLAN es nutzen.

Finden Sie die lokale IP-Adresse Ihres Rechners (z. B. `192.168.1.10`) und öffnen Sie `http://192.168.1.10:8080` auf einem beliebigen Gerät.

**Spracheingabe** erfordert HTTPS. Verwenden Sie `https://<Ihre-IP>:8443`. Der Browser zeigt eine Sicherheitswarnung wegen des selbstsignierten Zertifikats — das ist erwartet, einmalig akzeptieren. Auf iOS den Link in der Zertifikatswarnung tippen, um das Zertifikat herunterzuladen und über Einstellungen zu installieren (einmalig pro Gerät).

---

## Admin-Einstellungen Referenz

Benutzersymbol → **Einstellungen** (nur Admins).

**Ollama Cloud — API-Konten**

Ein oder mehrere Konten (Bezeichnung + API-Schlüssel) hinzufügen. DMH-AI wechselt automatisch zwischen allen hinzugefügten Konten — wenn eines sein Ratenlimit erreicht, übernimmt das nächste nahtlos. Sie können Schlüssel von mehreren Ollama-Konten hinzufügen, um Ihr Kontingent effektiv zu vervielfachen.

**Ollama Cloud — Empfohlene Modelle**

Sobald mindestens ein Konto vorhanden ist, erscheinen vier Modelle automatisch oben in der Modellauswahl — ohne weitere Konfiguration: **Schlagfertig**, **Lexicon**, **Tiefdenker** und **Mathe-Meister**.

**Ollama Cloud — Cloud-Modelle**

Weitere Cloud-Modelle über die drei empfohlenen hinaus hinzufügen. Das Suchfeld fragt das öffentliche Ollama-Modellverzeichnis ab — Sie können jedes Cloud-Modell direkt finden und hinzufügen, ohne ollama.com besuchen zu müssen. Hinzugefügte Modelle erscheinen im Abschnitt **☁ Cloud Models** der Modellauswahl.

**Ollama Local — Endpunkt-URL**

Standardmäßig verbindet sich DMH-AI mit Ollama unter `http://localhost:11434`. Ändern Sie dies, wenn Ollama auf einem anderen Rechner in Ihrem Netzwerk läuft (z. B. einem Heimserver).

---

## Websuche

DMH-AI enthält eine integrierte Websuche-Pipeline — ähnlich wie Perplexity oder ChatGPT Search, aber selbst gehostet und privat.

**Wie es funktioniert:**

1. Sie stellen eine Frage in beliebiger Sprache
2. Die KI entscheidet, ob Ihre Frage aktuelle Informationen aus dem Web benötigt (keine fest codierten Schlüsselwörter — sie versteht die Absicht)
3. Falls ja, sucht DMH-AI über die integrierte SearXNG-Instanz und ruft die besten Ergebnisse ab
4. Die KI fasst die Ergebnisse zu einer kohärenten, gut strukturierten Antwort mit aktuellen Informationen zusammen

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

---

## Architektur (für Entwickler)

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

**Echtes SSL-Zertifikat verwenden (optional)**

Wenn Sie eine Domain mit gültigem SSL-Zertifikat haben, richten Sie einen Reverse-Proxy (nginx, Caddy o. ä.) auf Port `8080` ein. Mit echtem HTTPS funktioniert die Spracheingabe ohne Zertifikatswarnung, und Port `8443` wird nicht mehr benötigt.

Ein gültiger HTTPS-Ursprung ermöglicht außerdem die Installation von DMH-AI als eigenständige App auf dem Smartphone — ohne App-Store:
- **Android (Chrome):** Seite öffnen → Drei-Punkte-Menü → **Zum Startbildschirm hinzufügen**
- **iOS (Safari):** Seite öffnen → Teilen-Symbol → **Zum Home-Bildschirm**

Die App startet dann im Vollbild und ist von einer nativen App nicht zu unterscheiden.

## Projektstruktur

```
code/
  index.html              # gesamtes Frontend (HTML + CSS + JS)
  backend/server.py       # Sitzungs-API, Datei-Upload, Such-Proxy, Logging
  nginx.conf              # Reverse-Proxy-Konfiguration
  Dockerfile              # nginx:alpine + python3
  start.sh                # Entrypoint: startet Python-Backend dann nginx
deploy/
  docker-compose.yml      # Deployment-Compose-Datei (maßgebliche Quelle)
  searxng-settings.yml    # SearXNG-Konfiguration (aktiviert JSON-API auf Port 8888)
  run.sh                  # Legacy-Direktstart-Skript (wird nach dist/ kopiert von build.sh)
build.sh                  # Linux/macOS: baut Docker-Image und erstellt dist/
build.bat                 # Windows: baut Docker-Image und erstellt dist/
install.sh                # Linux/macOS: installiert dist/ → ~/.dmhai/, registriert dmhai-Befehl
install.bat               # Windows: installiert dist/ → %USERPROFILE%\.dmhai\, fügt dmhai zum PATH hinzu
dmhai.bat                 # Windows: Verwaltungsskript (start/stop/restart/status)
dist/                     # erzeugt von build.sh — nicht manuell bearbeiten
~/.dmhai/                 # Live-Installation — alle Benutzerdaten befinden sich hier
```
