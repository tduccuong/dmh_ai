# DMH-AI

Eine selbst gehostete KI-Chat-App, die auf Ihrem Computer läuft — wie ChatGPT, aber privat, kostenlos und ganz Ihnen gehörend.

Da DMH-AI auf Ihrem eigenen Rechner läuft, **haben Sie die vollständige Kontrolle über Ihre Daten**. Gespräche, Begleitergedächtnis, private Notizen, Dateien — alles verbleibt auf Ihrer Hardware, in Ihrem Zuhause. Kein Dritter kann darauf zugreifen, es analysieren oder verwerten. Bei Cloud-KI-Modellen wird nur der Text jeder Anfrage zur Verarbeitung gesendet — nichts anderes verlässt Ihren Rechner.

DMH-AI ist ein Produkt der **DMHDigitrans e.K.**

## Screenshots

![Automatische Websuche](auto_web_search.png)
*Bei zeitkritischen Fragen durchsucht DMH-AI automatisch das Web, ruft aktuelle Daten ab und liefert eine belegte Antwort.*

---

![Bilder ansehen](see_images.png)
*Beliebiges Foto oder Video einfügen und Fragen dazu stellen.*

---

## DMH-AI — Ihr privater KI-Begleiter

Gesprächsorientiert, wie ChatGPT. Sie schreiben, die Antwort wird gestreamt zurückgegeben. Ideal für alltägliche Fragen, Schreibhilfe, Bildanalyse und Brainstorming — überall dort, wo Sie eine sofortige, private Antwort möchten.

Was DMH-AI zu mehr als einem Chat-Werkzeug macht:

- **Beliebige Datei einfügen.** PDFs, Word-Dokumente, Tabellen, Bilder, Videos. Stellen Sie inline Fragen dazu. Auf dem Handy können Sie direkt ins Chat fotografieren oder aufnehmen.
- **Automatische Websuche.** DMH-AI entscheidet selbst, ob Ihre Frage aktuelle Informationen benötigt. Falls ja, durchsucht er das Web, ruft die Seiten ab und liefert eine belegte Antwort — ohne dass Sie einen "Suchmodus" einschalten müssen.
- **`/memo` für Ihre privaten Notizen.** Tippen Sie `/memo Mein Homelab-SSH-Schlüssel ist X` oder `/memo Ich bevorzuge Tailwind gegenüber reinem CSS`, und DMH-AI merkt es sich. Beim nächsten passenden Thema — auch nach Monaten — werden diese Notizen automatisch abgerufen. **Verschlüsselt im Ruhezustand**, mit einem Schlüssel, der außerhalb der Datenbank liegt — selbst ein gestohlenes Backup kann sie nicht lesen.
- **Er wächst mit Ihnen.** DMH-AI baut im Laufe der Zeit ein Profil von Ihnen auf — Vorlieben, Kontext, was Sie ihm erzählt haben — und nutzt dieses Wissen für relevantere und persönlichere Antworten. Verbleibt auf Ihrer Hardware; in den Gesprächseinstellungen jederzeit einsehbar oder löschbar.
- **`/tts` liest Antworten vor.** Verwandeln Sie jede Antwort in natürliche Sprache.
- **Keine Speichergrenze.** Lange Sitzungen komprimieren alten Kontext intelligent. Sie stoßen nie an ein Token-Limit.

---

## Was Sie bekommen

- **Begleitergedächtnis & private Notizen** — automatisch erstelltes Profil + verschlüsselte `/memo`-Notizen, alles auf Ihrer Hardware
- **Integrierte Websuche** — wie Perplexity, aber selbst gehostet und privat; funktioniert in jeder Sprache
- **Reichhaltige Medienanhänge** — PDF, DOCX, XLSX, Bilder, Videos; auf dem Handy direkt ins Chat fotografieren oder aufnehmen
- **Sprachausgabe** — `/tts` liest jede Antwort vor
- **Mehrbenutzerunterstützung** — jede Person hat eigene Anmeldedaten, Verläufe und Dateien; Admin verwaltet Nutzer direkt in der App
- **Persistenter Chat-Verlauf** — alle Sitzungen gespeichert und durchsuchbar
- **Mehrsprachige Oberfläche** — Englisch, Vietnamesisch, Deutsch, Spanisch, Französisch
- **Zugriff von jedem Gerät im Heimnetzwerk** — Smartphone, Tablet, Laptop

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
./scripts/build.sh         # Docker-Images bauen und dist/ zusammenstellen
sudo ./dist/install.sh     # nach /opt/dmh_ai/ installieren und den Befehl dmh_ai registrieren
dmh_ai start        # App starten
```

Für eine eigenständige Installation auf Benutzerebene — alles unter `~/.dmh_ai/`, ohne sudo — verwenden Sie `--stage`:

```bash
./scripts/build.sh --stage
./dist/install.sh --stage     # ohne sudo
dmh_ai start
```

Öffnen Sie [http://localhost:8080](http://localhost:8080) im Browser.

### App verwalten

```bash
dmh_ai start      # starten
dmh_ai stop       # stoppen
dmh_ai restart    # neu starten (nimmt neuen Build automatisch auf)
dmh_ai status     # laufende Container anzeigen
dmh_ai logs       # Container-Protokolle anzeigen
```

Nach einer Code-Aktualisierung neu bauen und neu installieren:
```bash
./scripts/build.sh --no-export   # Images neu bauen ohne Tars zu exportieren (schneller)
sudo ./dist/install.sh           # installierte Konfiguration aktualisieren; Benutzerdaten bleiben erhalten
dmh_ai restart
```

### Erste Anmeldung

Beim ersten Start erstellt DMH-AI automatisch ein Standard-Admin-Konto:

| Benutzername | Passwort |
|---|---|
| `admin` | `dmh_ai` |

Anmelden, dann **sofort das Passwort ändern**: Benutzersymbol (oben rechts) → **Passwort ändern**.

---

## KI-Dienst verbinden (Admin)

DMH-AI benötigt ein KI-Backend. Der Admin konfiguriert dies einmalig in den Einstellungen. Nutzer wählen kein Modell aus.

### Standard — Ollama Cloud

Ollama bietet leistungsstarke Cloud-KI-Modelle kostenlos an, mit großzügigen Nutzungslimits. Dies ist der einfachste Einstieg: kein GPU, keine besonderen Hardwareanforderungen.

1. Gehen Sie zu [ollama.com](https://ollama.com) und erstellen Sie ein kostenloses Konto
2. Profilbild → **Settings** → **API Keys** → **Create new key**, Schlüssel kopieren
3. In DMH-AI: Benutzersymbol → **Einstellungen** → **Ollama Cloud — API-Konten** → **Konto hinzufügen**, Schlüssel einfügen

Das war's. DMH-AI steht allen Nutzern sofort zur Verfügung.

Bei diesem Setup wird nur der Text jeder KI-Anfrage zur Verarbeitung an Ollamas Server gesendet. Alle Nutzerdaten — Chat-Verlauf, Begleitergedächtnis, hochgeladene Dateien, `/memo`-Notizen — verbleiben auf Ihrem Rechner und werden niemals an Dritte weitergegeben.

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

Standardmäßig bindet DMH-AI nur an `127.0.0.1` — privat erreichbar vom Host, der es ausführt. Um es auf allen Netzwerkschnittstellen bereitzustellen, damit Smartphones, Tablets und andere Computer im selben WLAN darauf zugreifen können, setzen Sie `DMHAI_BIND_HOST=0.0.0.0` vor dem Start:

```
DMHAI_BIND_HOST=0.0.0.0 dmh_ai start
```

Finden Sie dann die lokale IP-Adresse Ihres Rechners (z. B. `192.168.1.10`) und öffnen Sie `http://192.168.1.10:8080` auf einem beliebigen Gerät.

**Spracheingabe** erfordert HTTPS. Verwenden Sie `https://<Ihre-IP>:8443`. Der Browser zeigt eine Sicherheitswarnung wegen des selbstsignierten Zertifikats — das ist erwartet, einmalig akzeptieren. Auf iOS den Link in der Zertifikatswarnung tippen, um das Zertifikat herunterzuladen und über Einstellungen zu installieren (einmalig pro Gerät).

Um zu privatem (`127.0.0.1`-only) Zugriff zurückzukehren, ohne die Umgebungsvariable neu starten: `dmh_ai restart`.

---

## Admin-Einstellungen Referenz

Benutzersymbol → **Einstellungen** (nur Admins).

**Ollama Cloud — API-Konten**

Ein oder mehrere Konten (Bezeichnung + API-Schlüssel) hinzufügen. DMH-AI wechselt automatisch zwischen allen hinzugefügten Konten — wenn eines sein Ratenlimit erreicht, übernimmt das nächste nahtlos.

**Beispiel:** Eine vierköpfige Familie legt je ein kostenloses Ollama-Konto an und trägt alle vier Schlüssel hier ein. DMH-AI verteilt die Last automatisch und transparent — kein Familienmitglied muss sich darum kümmern, welches Konto gerade genutzt wird oder ob ein Limit erreicht wurde.

**KI-Modelle**

Konfigurieren Sie, welches KI-Modell welche Rolle übernimmt: DMH-AIr-Gespräche, schnelle Klassifizierungen (Swift), Langkontext-Zusammenfassung (Oracle), Bild- und Videoanalyse sowie Embeddings. Jede Rolle kann ein anderes, für die jeweilige Aufgabe optimiertes Modell verwenden.

**Ollama Local — Endpunkt-URL**

Standardmäßig verbindet sich DMH-AI mit Ollama unter `http://localhost:11434`. Ändern Sie dies, wenn Ollama auf einem anderen Rechner in Ihrem Netzwerk läuft (z. B. einem Heimserver).

---

## Websuche

DMH-AI enthält eine integrierte Websuche-Pipeline — ähnlich wie Perplexity oder ChatGPT Search, aber selbst gehostet und privat.

**Wie es funktioniert:**

1. Sie stellen eine Frage in beliebiger Sprache
2. Die KI entscheidet, ob Ihre Frage aktuelle Informationen aus dem Web benötigt (keine fest codierten Schlüsselwörter — sie versteht die Absicht)
3. Falls ja, sucht DMH-AI über die integrierte SearXNG-Instanz und ruft die besten Ergebnisse ab
4. Die KI fasst die Ergebnisse zu einer kohärenten, gut strukturierten Antwort mit Quellenangabe zusammen

Sie müssen nichts anders machen — stellen Sie einfach Ihre Frage. Suchanfragen laufen über Ihre eigene SearXNG-Instanz, nicht über Drittanbieter-Dienste.

---

## Ihre Daten

Nach dem Ausführen von `./dist/install.sh` werden alle Live-Daten in `~/.dmh_ai/` gespeichert:

- `~/.dmh_ai/db/` — Chat-Verlauf (SQLite-Datenbank)
- `~/.dmh_ai/secrets/` — Hauptschlüssel für die Verschlüsselung von `/memo`-Notizen (sichern Sie diesen **getrennt** von der Datenbank — siehe unten)
- `~/.dmh_ai/user_assets/` — hochgeladene Dateien, nach Sitzung organisiert
- `~/.dmh_ai/system_logs/system.log` — Websuche- und System-Protokoll

`./dist/install.sh` erneut auszuführen ist sicher — vorhandene Datendateien werden nie überschrieben. Jede Datei wird nur dann aus `dist/` kopiert, wenn sie in `~/.dmh_ai/` noch nicht vorhanden ist.

Zum Sichern oder Übertragen auf einen anderen Rechner kopieren Sie `~/.dmh_ai/` und führen Sie `./dist/install.sh` auf dem neuen Rechner aus.

**Zur `/memo`-Verschlüsselung.** Ihre gespeicherten Notizen werden mit einem benutzerspezifischen Schlüssel verschlüsselt, der seinerseits durch einen Hauptschlüssel in `~/.dmh_ai/secrets/` umschlossen ist. Sichern Sie den `secrets/`-Ordner **getrennt** von der Datenbank — genau das ist der Zweck: ein gestohlenes DB-Backup allein kann Ihre Notizen nicht entschlüsseln. Sollten Sie den `secrets/`-Ordner verlieren, sind die bestehenden Notizen nicht mehr lesbar (DMH-AI lässt Sie weiterhin neue unter einem frischen Schlüssel speichern).

Weitere Nutzer hinzufügen: Benutzersymbol → **Benutzer verwalten**.
