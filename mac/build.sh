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
"$PYTHON" -c 'import mlx_whisper' 2>/dev/null || echo "Peringatan: mlx-whisper belum terpasang (pip install -r requirements.txt)."

echo "Membangun Meeting Notes v$VERSION"
echo "  Python : $PYTHON"
echo "  Repo   : $REPO"
swift build -c release

APP="build/MeetingNotes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetingNotes "$APP/Contents/MacOS/MeetingNotes"
sed -e "s|__PYTHON__|$PYTHON|" -e "s|__REPO__|$REPO|" -e "s|__VERSION__|$VERSION|" Info.plist \
    > "$APP/Contents/Info.plist"
# Tanda tangan lokal (ad-hoc) agar macOS mau memberi izin mikrofon & rekam audio.
codesign --force --deep --sign - "$APP"

echo
echo "Selesai: mac/$APP"
echo "Jalankan: open mac/$APP"
