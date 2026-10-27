"""Menyimpan notulen rapat (MoM) sebagai Markdown (.md) dan Word (.docx)."""

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from docx import Document
from docx.enum.text import WD_BREAK

from . import __version__
from .summarizer import MeetingSummary
from .transcriber import Segment, format_timestamp

FOOTER = f"Dibuat otomatis oleh Meeting Notes v{__version__}"


@dataclass
class MeetingInfo:
    started_at: datetime
    duration_seconds: float


def _title(info: MeetingInfo, summary: MeetingSummary | None) -> str:
    return summary.title if summary else f"Rapat {info.started_at:%d-%m-%Y}"


Corrections = dict[tuple[str, str], int]


def _bullets(items: list[str]) -> list[str]:
    return [f"- {item}" for item in items] or ["- -"]


def render_markdown(
    info: MeetingInfo, paragraphs: list[Segment], summary: MeetingSummary | None, note: str | None = None,
    corrections: Corrections | None = None,
) -> str:
    lines = [
        f"# {_title(info, summary)}",
        "",
        f"**Tanggal:** {info.started_at:%d-%m-%Y %H:%M}  ",
        f"**Durasi:** {format_timestamp(info.duration_seconds)}  ",
    ]
    if summary:
        lines.append(f"**Peserta:** {', '.join(summary.participants) or '-'}")
    lines.append("")
    if note:
        lines += [f"> ⚠️ {note}", ""]

    if summary:
        lines += ["## Ringkasan Eksekutif", "", summary.executive_summary, ""]
        lines += ["## Keputusan Utama", "", *_bullets(summary.decisions), ""]
        lines += ["## Action Items", ""]
        if summary.action_items:
            lines += ["| No | Tugas | Penanggung Jawab | Tenggat |", "|---|---|---|---|"]
            lines += [
                f"| {i} | {a.task} | {a.owner} | {a.deadline} |".replace("\n", " ")
                for i, a in enumerate(summary.action_items, 1)
            ]
        else:
            lines.append("- -")
        lines += ["", "## Pembahasan per Agenda", ""]
        for i, item in enumerate(summary.agenda, 1):
            lines += [f"### {i}. {item.topic} `{item.start_time}`", "", *_bullets(item.points)]
            if item.decisions:
                lines += ["", "**Keputusan:**", *_bullets(item.decisions)]
            lines.append("")
        lines += ["## Pertanyaan Terbuka", "", *_bullets(summary.open_questions), ""]

    lines += ["---", "", "## Lampiran: Transkrip Lengkap", ""]
    for p in paragraphs:
        lines += [f"**[{format_timestamp(p.start)}]** {p.text}", ""]
    if not paragraphs:
        lines += ["_(tidak ada suara terdeteksi)_", ""]
    if corrections:
        lines += ["## Lampiran: Koreksi Otomatis", "", "| Tertulis | Dikoreksi menjadi | Jumlah |", "|---|---|---|"]
        lines += [f"| {wrong} | {correct} | {n} |" for (wrong, correct), n in corrections.items()]
        lines.append("")
    lines += ["---", f"_{FOOTER}_"]
    return "\n".join(lines) + "\n"


def write_docx(
    path: Path, info: MeetingInfo, paragraphs: list[Segment], summary: MeetingSummary | None, note: str | None = None,
    corrections: Corrections | None = None,
) -> Path:
    doc = Document()
    doc.add_heading(_title(info, summary), level=0)
    meta = f"Tanggal: {info.started_at:%d-%m-%Y %H:%M}\nDurasi: {format_timestamp(info.duration_seconds)}"
    if summary:
        meta += f"\nPeserta: {', '.join(summary.participants) or '-'}"
    doc.add_paragraph(meta)
    if note:
        doc.add_paragraph(f"⚠️ {note}")

    def bullets(items: list[str]) -> None:
        for item in items or ["-"]:
            doc.add_paragraph(item, style="List Bullet")

    if summary:
        doc.add_heading("Ringkasan Eksekutif", level=1)
        doc.add_paragraph(summary.executive_summary)
        doc.add_heading("Keputusan Utama", level=1)
        bullets(summary.decisions)

        doc.add_heading("Action Items", level=1)
        if summary.action_items:
            table = doc.add_table(rows=1, cols=4)
            table.style = "Table Grid"
            for cell, text in zip(table.rows[0].cells, ["No", "Tugas", "Penanggung Jawab", "Tenggat"], strict=True):
                cell.text = text
                cell.paragraphs[0].runs[0].bold = True
            for i, a in enumerate(summary.action_items, 1):
                for cell, text in zip(table.add_row().cells, [str(i), a.task, a.owner, a.deadline], strict=True):
                    cell.text = text
        else:
            bullets([])

        doc.add_heading("Pembahasan per Agenda", level=1)
        for i, item in enumerate(summary.agenda, 1):
            doc.add_heading(f"{i}. {item.topic} ({item.start_time})", level=2)
            bullets(item.points)
            if item.decisions:
                doc.add_paragraph().add_run("Keputusan:").bold = True
                bullets(item.decisions)

        doc.add_heading("Pertanyaan Terbuka", level=1)
        bullets(summary.open_questions)

    doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)
    doc.add_heading("Lampiran: Transkrip Lengkap", level=1)
    for p in paragraphs:
        para = doc.add_paragraph()
        para.add_run(f"[{format_timestamp(p.start)}] ").bold = True
        para.add_run(p.text)
    if not paragraphs:
        doc.add_paragraph("(tidak ada suara terdeteksi)")
    if corrections:
        doc.add_heading("Lampiran: Koreksi Otomatis", level=1)
        table = doc.add_table(rows=1, cols=3)
        table.style = "Table Grid"
        for cell, text in zip(table.rows[0].cells, ["Tertulis", "Dikoreksi menjadi", "Jumlah"], strict=True):
            cell.text = text
            cell.paragraphs[0].runs[0].bold = True
        for (wrong, correct), n in corrections.items():
            for cell, text in zip(table.add_row().cells, [wrong, correct, str(n)], strict=True):
                cell.text = text
    doc.sections[0].footer.paragraphs[0].text = FOOTER

    doc.save(path)
    return path
