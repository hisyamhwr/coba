"""Titik masuk aplikasi.

    python -m meeting_notes                 # buka widget
    python -m meeting_notes proses rapat.wav  # proses rekaman yang sudah ada
"""

import argparse
from pathlib import Path

from .config import Settings


def main() -> None:
    parser = argparse.ArgumentParser(prog="meeting_notes", description="Agent pencatat rapat")
    sub = parser.add_subparsers(dest="command")
    proses = sub.add_parser("proses", help="Transkripsi dan rangkum file audio yang sudah ada")
    proses.add_argument("audio", type=Path, help="File audio (wav, mp3, m4a, ...)")
    args = parser.parse_args()

    if args.command == "proses":
        from .pipeline import process_recording

        result = process_recording(args.audio, Settings())
        print(f"Markdown : {result.markdown_path}\nWord     : {result.docx_path}")
        if result.note:
            print(f"Catatan  : {result.note}")
    else:
        from .widget import main as run_widget

        run_widget()


if __name__ == "__main__":
    main()
