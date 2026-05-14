#!/usr/bin/env python3
"""
Deterministic generator for the kb_handbook demo fixture.

Produces `mitarbeiterhandbuch.pdf` — a synthetic German employee
handbook covering Urlaub / Spesen / Elternzeit / Krankheit / etc.
Output is committed alongside this script so the demo is
replayable without re-running this generator.

Run (anywhere with fpdf2 installed; e.g. the dmh-ai-sandbox
container has it preinstalled per `code/sandbox/Dockerfile`):

    python3 generate_handbook.py

The PDF must be regenerated only when the content below is edited.
Treat the committed PDF as the canonical demo artifact.
"""
from fpdf import FPDF


# fpdf2's default core fonts (Helvetica / Times / Courier) handle
# Latin-1; the German umlauts in our content (ä, ö, ü, ß) are inside
# that range so no font file is needed. Keeping the font core also
# makes the PDF tiny (~5 KB).
FONT = "Helvetica"


CONTENT = [
    ("1. Willkommen", [
        "Willkommen bei der DMH SME Demo GmbH. Dieses Handbuch fasst die wichtigsten",
        "Regelungen für alle festangestellten Mitarbeitenden zusammen. Es gilt ergänzend",
        "zum individuellen Arbeitsvertrag.",
        "",
        "Stand der letzten Überarbeitung: Mai 2026.",
    ]),
    ("2. Arbeitszeiten und Anwesenheit", [
        "Die regelmässige Wochenarbeitszeit beträgt 40 Stunden, verteilt auf Montag bis",
        "Freitag. Kernarbeitszeit ist 10:00 bis 16:00 Uhr; ausserhalb dieser Zeit ist",
        "Gleitzeit möglich.",
        "",
        "Homeoffice ist nach Absprache mit der direkten Führungskraft an bis zu drei",
        "Tagen pro Woche möglich. An mindestens zwei Tagen pro Woche wird die Anwesenheit",
        "im Büro erwartet.",
    ]),
    ("3. Urlaub und freie Tage", [
        "Der gesetzliche Mindesturlaub beträgt 24 Werktage pro Kalenderjahr.",
        "Zusätzlich gewährt das Unternehmen folgende Staffel nach Betriebszugehörigkeit:",
        "",
        "  - Nach 3 Jahren Betriebszugehörigkeit: 28 Urlaubstage pro Jahr.",
        "  - Nach 5 Jahren Betriebszugehörigkeit: 30 Urlaubstage pro Jahr.",
        "  - Nach 10 Jahren Betriebszugehörigkeit: 32 Urlaubstage pro Jahr.",
        "",
        "Sonderurlaub wird in folgenden Fällen gewährt:",
        "",
        "  - Eigene Hochzeit: 2 Tage.",
        "  - Umzug aus betrieblichen Gründen: 1 Tag.",
        "  - Geburt eines eigenen Kindes: 5 Tage.",
        "  - Todesfall im engsten Familienkreis: 3 Tage.",
        "",
        "Urlaubsanträge sind spätestens 4 Wochen vor Antritt schriftlich einzureichen.",
    ]),
    ("4. Elternzeit", [
        "Pro Kind kann jede/r Mitarbeitende bis zu 3 Jahre Elternzeit nehmen. Die",
        "Elternzeit ist mindestens 7 Wochen vor dem geplanten Beginn schriftlich",
        "anzukündigen.",
        "",
        "Während der Elternzeit besteht ein gesetzlich geregelter Kündigungsschutz.",
        "Eine Wiederaufnahme der Tätigkeit kann in Teilzeit zwischen 15 und 32 Stunden",
        "pro Woche vereinbart werden.",
    ]),
    ("5. Spesen und Reisen", [
        "Tagespauschale für Inlandsreisen: 28 EUR bei mehr als 8 Stunden Abwesenheit;",
        "14 EUR bei 8 Stunden oder weniger.",
        "",
        "Auslandsreisen werden gemäss den jeweils geltenden Pauschalen des Bundessteuer-",
        "blattes abgerechnet. Übernachtungskosten sind bis zu 120 EUR pro Nacht im",
        "Inland und 200 EUR pro Nacht im Ausland erstattungsfähig.",
        "",
        "Reisekosten werden monatlich über das interne Spesen-Tool abgerechnet. Belege",
        "müssen im Original oder als hochgeladenes Foto eingereicht werden.",
    ]),
    ("6. Krankheitsfall", [
        "Erkrankungen sind am ersten Krankheitstag bis 9:00 Uhr telefonisch oder per",
        "E-Mail bei der direkten Führungskraft zu melden.",
        "",
        "Ab dem dritten Krankheitstag ist eine Arbeitsunfähigkeitsbescheinigung (AU)",
        "vorzulegen. Die AU kann elektronisch über die Krankenkasse übermittelt werden.",
    ]),
    ("7. Datenschutz und Vertraulichkeit", [
        "Externe Datenträger (USB-Sticks, externe Festplatten) dürfen nicht ohne",
        "schriftliche IT-Freigabe an Firmen-Hardware angeschlossen werden.",
        "",
        "Kundendaten dürfen ausschliesslich über die genehmigten Systeme (CRM, KB,",
        "interne Dateifreigaben) verarbeitet werden. Eine Weitergabe an Dritte ist",
        "ohne ausdrückliche schriftliche Zustimmung des Datenschutzbeauftragten",
        "untersagt.",
    ]),
    ("8. Kündigung", [
        "Es gelten die gesetzlichen Kündigungsfristen nach Paragraph 622 BGB:",
        "",
        "  - Während der Probezeit (6 Monate): 2 Wochen.",
        "  - Nach der Probezeit: 4 Wochen zum 15. oder Monatsende.",
        "  - Nach 5 Jahren Betriebszugehörigkeit: 2 Monate zum Monatsende.",
        "  - Nach 10 Jahren Betriebszugehörigkeit: 4 Monate zum Monatsende.",
        "",
        "Kündigungen sind ausschliesslich in schriftlicher Form gültig. Die elektronische",
        "Form (E-Mail, Fax) ist nicht ausreichend.",
    ]),
]


def build_pdf(out_path: str) -> None:
    pdf = FPDF(format="A4", unit="mm")
    pdf.set_auto_page_break(auto=True, margin=15)
    pdf.set_margins(left=20, top=20, right=20)

    # ── Title page ───────────────────────────────────────────────────────
    pdf.add_page()
    pdf.set_font(FONT, "B", 22)
    pdf.cell(0, 14, "Mitarbeiterhandbuch", new_x="LMARGIN", new_y="NEXT", align="C")

    pdf.set_font(FONT, "", 12)
    pdf.cell(0, 8, "DMH SME Demo GmbH", new_x="LMARGIN", new_y="NEXT", align="C")
    pdf.cell(0, 8, "Stand: Mai 2026", new_x="LMARGIN", new_y="NEXT", align="C")
    pdf.ln(10)

    # ── Sections ─────────────────────────────────────────────────────────
    for heading, lines in CONTENT:
        pdf.ln(4)
        pdf.set_font(FONT, "B", 14)
        pdf.set_x(pdf.l_margin)
        pdf.cell(0, 8, heading, new_x="LMARGIN", new_y="NEXT")
        pdf.set_font(FONT, "", 11)
        for line in lines:
            if line == "":
                pdf.ln(3)
            else:
                pdf.set_x(pdf.l_margin)
                pdf.multi_cell(w=pdf.w - pdf.l_margin - pdf.r_margin,
                               h=6, text=line)

    pdf.output(out_path)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    build_pdf(os.path.join(here, "mitarbeiterhandbuch.pdf"))
