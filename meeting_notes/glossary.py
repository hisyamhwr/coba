"""Kamus istilah yang belajar sendiri dari setiap rapat.

Disimpan sebagai file teks biasa (satu istilah per baris) supaya bisa diedit manual bila perlu.
Istilah yang paling baru muncul ditaruh paling atas, dan itulah yang diprioritaskan sebagai petunjuk Whisper.
"""

import re
from pathlib import Path

MAX_TERMS = 300
HEADER = (
    "# Kamus istilah Meeting Notes. Diperbarui otomatis setiap rapat; istilah terbaru di atas.\n"
    "# Boleh ditambah atau dihapus manual, satu istilah per baris.\n"
)


class Glossary:
    def __init__(self, path: Path):
        self.path = path
        self.terms: list[str] = []
        if path.exists():
            lines = path.read_text(encoding="utf-8").splitlines()
            self.terms = _dedupe(line.strip() for line in lines if line.strip() and not line.startswith("#"))

    def merge(self, new_terms: list[str]) -> None:
        self.terms = _dedupe([t.strip() for t in new_terms if t.strip()] + self.terms)[:MAX_TERMS]

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(HEADER + "\n".join(self.terms) + "\n", encoding="utf-8")

    def whisper_hint(self, max_chars: int = 400) -> str:
        """Istilah teratas yang muat di prompt Whisper (dibatasi +-224 token)."""
        picked, used = [], 0
        for term in self.terms:
            if used + len(term) + 2 > max_chars:
                break
            picked.append(term)
            used += len(term) + 2
        return ", ".join(picked)


def _dedupe(terms) -> list[str]:
    seen, result = set(), []
    for term in terms:
        key = term.casefold()
        if key not in seen:
            seen.add(key)
            result.append(term)
    return result


def apply_corrections(text: str, corrections: list[tuple[str, str]]) -> tuple[str, dict[tuple[str, str], int]]:
    """Terapkan koreksi salah dengar. Mengembalikan teks baru dan jumlah penggantian per koreksi."""
    counts: dict[tuple[str, str], int] = {}
    for wrong, correct in corrections:
        if not wrong.strip() or wrong == correct:
            continue
        pattern = re.escape(wrong)
        if re.match(r"\w", wrong):
            pattern = r"\b" + pattern
        if re.search(r"\w$", wrong):
            pattern += r"\b"
        # Koreksi yang hanya beda huruf besar/kecil (voip -> VoIP) harus dicocokkan persis.
        flags = re.IGNORECASE if wrong.casefold() != correct.casefold() else 0
        text, n = re.subn(pattern, lambda _m, c=correct: c, text, flags=flags)
        if n:
            counts[(wrong, correct)] = counts.get((wrong, correct), 0) + n
    return text, counts
