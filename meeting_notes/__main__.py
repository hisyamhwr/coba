"""Titik masuk aplikasi.

    python -m meeting_notes                 # buka widget
    python -m meeting_notes proses rapat.wav  # proses rekaman yang sudah ada
    python -m meeting_notes bandingkan rapat.wav --mulai 60 --durasi 300  # uji tanding mesin transkripsi
"""

import argparse
import json
from datetime import datetime
from pathlib import Path

from .config import Settings


def main() -> None:
    parser = argparse.ArgumentParser(prog="meeting_notes", description="Agent pencatat rapat")
    sub = parser.add_subparsers(dest="command")
    proses = sub.add_parser("proses", help="Transkripsi dan rangkum file audio yang sudah ada")
    proses.add_argument("audio", type=Path, help="File audio (wav, mp3, m4a, ...)")
    proses.add_argument("--penting", type=Path, help="File JSON berisi daftar detik 'Tandai penting'")
    proses.add_argument("--mulai", help="Waktu mulai rapat (ISO 8601), untuk nama file dan tanggal notulen")
    proses.add_argument("--json", action="store_true", help="Keluaran untuk aplikasi Mac: STATUS/RESULT per baris")
    banding = sub.add_parser("bandingkan", help="Bandingkan hasil transkripsi beberapa mesin pada rekaman yang sama")
    banding.add_argument("audio", type=Path, help="File audio (wav, mp3, m4a, ...)")
    banding.add_argument("--mulai", type=float, default=0, help="Detik awal potongan (default 0)")
    banding.add_argument("--durasi", type=float, default=300, help="Panjang potongan dalam detik (default 300)")
    banding.add_argument("--tanpa-lokal", action="store_true", help="Lewati Whisper lokal")
    args = parser.parse_args()

    if args.command == "proses":
        from .pipeline import process_recording

        marks = json.loads(args.penting.read_text()) if args.penting else []
        started_at = datetime.fromisoformat(args.mulai) if args.mulai else None
        on_status = (lambda msg: print(f"STATUS\t{msg}", flush=True)) if args.json else print
        result = process_recording(args.audio, Settings(), started_at, on_status, marks=marks)
        if args.json:
            print("RESULT\t" + json.dumps({
                "title": result.title, "markdown": str(result.markdown_path), "docx": str(result.docx_path),
                "decisions": result.decisions, "action_items": result.action_items, "note": result.note,
            }), flush=True)
        else:
            print(f"Markdown : {result.markdown_path}\nWord     : {result.docx_path}")
            if result.note:
                print(f"Catatan  : {result.note}")
    elif args.command == "bandingkan":
        from .compare import compare, open_report

        report = compare(args.audio, Settings(), args.mulai, args.durasi, include_local=not args.tanpa_lokal)
        print(f"Hasil: {report}")
        open_report(report)
    else:
        from .widget import main as run_widget

        run_widget()


if __name__ == "__main__":
    main()
