"""Widget kecil yang selalu tampil di atas jendela lain: klik untuk mulai/berhenti mencatat rapat."""

import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
from datetime import datetime
from pathlib import Path

from . import __version__
from .config import Settings
from .pipeline import process_recording
from .recorder import Recorder
from .transcriber import Transcriber, format_timestamp

BG = "#1f2329"
FG = "#e8eaed"
MUTED = "#9aa0a6"
RED = "#e5484d"
GREEN = "#30a46c"


def open_path(path: Path) -> None:
    if sys.platform.startswith("win"):
        os.startfile(path)  # type: ignore[attr-defined]
    elif sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path)])


class MeetingWidget:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.transcriber = Transcriber(settings.whisper_model, settings.language, settings.whisper_engine)
        self.recorder: Recorder | None = None
        self.started_at: datetime | None = None
        self.last_result_dir: Path | None = None
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.state = "idle"

        self.root = tk.Tk()
        self.root.title(f"Meeting Notes v{__version__}")
        self.root.configure(bg=BG, padx=14, pady=12)
        self.root.attributes("-topmost", True)
        self.root.resizable(False, False)

        self.timer = tk.Label(self.root, text="00:00", font=("Helvetica", 22, "bold"), bg=BG, fg=FG)
        self.timer.pack()
        self.meter = tk.Canvas(self.root, width=200, height=6, bg="#2d3239", highlightthickness=0)
        self.meter.pack(pady=(4, 8))
        self.meter_bar = self.meter.create_rectangle(0, 0, 0, 6, fill=GREEN, width=0)
        self.button = tk.Button(
            self.root, text="●  Mulai Catat", width=18, font=("Helvetica", 12, "bold"),
            bg=GREEN, fg="white", activebackground=GREEN, relief="flat", command=self.toggle,
        )
        self.button.pack()
        self.status = tk.Label(
            self.root, text="Siap. Klik untuk mulai mendengarkan.", wraplength=220,
            font=("Helvetica", 9), bg=BG, fg=MUTED, justify="center",
        )
        self.status.pack(pady=(8, 0))
        self.open_button = tk.Button(
            self.root, text="Buka folder notulen", font=("Helvetica", 9), relief="flat",
            command=lambda: open_path(self.last_result_dir or self.settings.output_dir),
        )

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        # Unduh model Whisper di latar belakang (sekali saja) supaya tidak menunggu saat rapat selesai.
        if settings.transcription_engine == "lokal":
            threading.Thread(target=self._download_model, daemon=True).start()
        self.root.after(100, self._tick)

    def _download_model(self) -> None:
        try:
            self.transcriber.download()
        except Exception:  # noqa: BLE001 - dicoba lagi otomatis saat rapat diproses
            self.events.put(("download_failed", None))

    def toggle(self) -> None:
        if self.state == "idle":
            self.start()
        elif self.state == "recording":
            self.stop()

    def start(self) -> None:
        self.started_at = datetime.now()
        workdir = self.settings.output_dir / "rekaman" / f"{self.started_at:%Y-%m-%d_%H%M%S}"
        self.recorder = Recorder(workdir, self.settings.sample_rate, self.settings.capture_system_audio)
        try:
            warnings = self.recorder.start()
        except Exception as exc:  # noqa: BLE001
            self.set_status(f"Tidak bisa mengakses mikrofon: {exc}")
            return
        self.state = "recording"
        self.open_button.pack_forget()
        self.button.configure(text="■  Selesai & Rangkum", bg=RED, activebackground=RED)
        self.set_status(" ".join(warnings) or "Mendengarkan rapat...")

    def stop(self) -> None:
        self.state = "processing"
        self.button.configure(text="Memproses...", state="disabled", bg="#4a5059")
        self.meter.coords(self.meter_bar, 0, 0, 0, 6)
        threading.Thread(target=self._process, daemon=True).start()

    def _process(self) -> None:
        try:
            audio = self.recorder.stop()
            result = process_recording(
                audio, self.settings, self.started_at,
                on_status=lambda msg: self.events.put(("status", msg)),
                transcriber=self.transcriber,
            )
            self.events.put(("done", result))
        except Exception as exc:  # noqa: BLE001
            self.events.put(("error", exc))

    def _tick(self) -> None:
        if self.state == "recording" and self.recorder:
            elapsed = (datetime.now() - self.started_at).total_seconds()
            self.timer.configure(text=format_timestamp(elapsed))
            level = min(self.recorder.level * 8, 1.0)
            self.meter.coords(self.meter_bar, 0, 0, int(200 * level), 6)
            if self.recorder.errors:
                self.set_status(f"Masalah rekaman: {self.recorder.errors[0]}")

        while not self.events.empty():
            kind, payload = self.events.get()
            if kind == "status":
                self.set_status(str(payload))
            elif kind == "download_failed":
                # Jangan menimpa status rekaman, proses, atau hasil: model diunduh ulang saat diproses.
                if self.state == "recording":
                    self.set_status("Mendengarkan rapat... (Model Whisper belum terunduh, akan dicoba lagi.)")
                elif self.state == "idle" and not self.open_button.winfo_ismapped():
                    self.set_status("Model Whisper belum terunduh, cek internet. Akan dicoba lagi.")
            elif kind == "done":
                self.last_result_dir = payload.markdown_path.parent
                note = f"\n{payload.note}" if payload.note else ""
                self.set_status(f"Tersimpan: {payload.markdown_path.name}{note}")
                self.reset()
                self.open_button.configure(text="Buka folder notulen")
                self.open_button.pack(pady=(6, 0))
            elif kind == "error":
                # Rekaman audio tetap aman; arahkan pengguna ke foldernya agar bisa diproses ulang.
                self.last_result_dir = self.recorder.workdir if self.recorder else None
                self.set_status(f"Gagal memproses: {payload}\nRekaman aman tersimpan, bisa diproses ulang.")
                self.reset()
                self.open_button.configure(text="Buka folder rekaman")
                self.open_button.pack(pady=(6, 0))

        self.root.after(100, self._tick)

    def reset(self) -> None:
        self.state = "idle"
        self.button.configure(text="●  Mulai Catat", state="normal", bg=GREEN, activebackground=GREEN)

    def set_status(self, text: str) -> None:
        self.status.configure(text=text)

    def on_close(self) -> None:
        if self.state == "recording":
            self.set_status("Klik 'Selesai & Rangkum' dulu agar rapat tersimpan.")
            return
        if self.state == "processing":
            self.set_status("Tunggu sebentar, notulen sedang diproses...")
            return
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()


def main() -> None:
    MeetingWidget(Settings()).run()
