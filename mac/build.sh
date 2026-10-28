#!/bin/bash
# Membangun MeetingNotes.app. Jalankan dari environment conda yang berisi meeting_notes:
#   conda activate meeting && ./mac/build.sh
set -euo pipefail

cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
PYTHON="${MN_PYTHON:-$(command -v python3 || command -v python)}"
VERSION="$(cd "$REPO" && "$PYTHON" -c 'import meeting_notes; print(meeting_notes.__version__)')" || {
    echo "Python di $PYTHON belum berisi meeting_notes. Jalankan 'conda activate meeting' dulu." >&2
    exit 1
}
# Pastikan semua library terpasang di Python yang dipakai aplikasi (bukan Python lain, mis. conda "base").
if ! "$PYTHON" -c 'import soundfile, faster_whisper, docx, dotenv, pydantic, anthropic, requests' 2>/dev/null; then
    echo "Memasang library Python yang belum ada ke $PYTHON ..."
    "$PYTHON" -m pip install -r "$REPO/requirements.txt"
fi
"$PYTHON" -c 'import mlx_whisper' 2>/dev/null || echo "Peringatan: mlx-whisper belum terpasang."

echo "Membangun Meeting Notes v$VERSION"
echo "  Python : $PYTHON"
echo "  Repo   : $REPO"
mkdir -p build
LOG="build/swift-build.log"
if ! swift build -c release >"$LOG" 2>&1; then
    echo
    echo "BUILD GAGAL. Pesan error (kirim bagian ini):"
    echo "------------------------------------------------------------"
    grep -E "error:" -A4 "$LOG" | grep -v "^--$" | head -80
    echo "------------------------------------------------------------"
    echo "Log lengkap: mac/$LOG"
    exit 1
fi

APP="build/MeetingNotes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Lokasi hasil build berbeda antar versi Swift; tanyakan langsung ke Swift.
BIN="$(swift build -c release --show-bin-path)/MeetingNotes"
[ -f "$BIN" ] || BIN="$(find .build -type f -name MeetingNotes -perm -u+x -path '*elease*' | head -1)"
cp "$BIN" "$APP/Contents/MacOS/MeetingNotes"
sed -e "s|__PYTHON__|$PYTHON|" -e "s|__REPO__|$REPO|" -e "s|__VERSION__|$VERSION|" Info.plist \
    > "$APP/Contents/Info.plist"
# Tanda tangan lokal (ad-hoc) agar macOS mau memberi izin mikrofon & rekam audio.
codesign --force --deep --sign - "$APP"

echo
echo "Selesai: mac/$APP"
echo "Jalankan: open mac/$APP"
