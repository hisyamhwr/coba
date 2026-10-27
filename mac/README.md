# Meeting Notes untuk Mac (2.0.0)

Aplikasi menu bar dengan "pulau" ala Dynamic Island di tengah atas layar:

| Status | Tampilan |
|---|---|
| Siap | Kapsul kecil "Meeting Notes"; klik untuk membuka tombol **Mulai Catat** |
| Merekam | Titik merah, timer, gelombang suara; klik untuk melihat transkrip live, **Tandai penting**, dan tombol stop oranye |
| Memproses | Langkah *Mentranskrip → Mengoreksi → Menyusun MoM* |
| Selesai | Judul rapat, jumlah keputusan & action item, tombol **Buka MoM**, **Salin**, **Folder** |

Shortcut global **⌃⌥M** (Control + Option + M) untuk mulai/berhenti dari aplikasi mana pun.

## Cara kerja

- **Aplikasi Swift (folder ini):** merekam mic + audio Zoom/Meet/Teams secara digital (ScreenCaptureKit,
  tanpa BlackHole, tetap jalan saat pakai headphone), menampilkan transkrip live, dan mencatat momen penting.
- **"Otak" Python 1.x (folder `meeting_notes`):** setelah rapat selesai, aplikasi menjalankan
  `python -m meeting_notes proses` untuk transkripsi akurat, koreksi Claude, kamus, dan MoM. Semua pengaturan
  `.env` (mesin transkripsi, Claude, dll.) tetap berlaku.
- Transkrip live memakai pengenal suara bawaan macOS (bahasa Indonesia), hanya untuk ditampilkan. Bila Mac tidak
  mendukung versi on-device, macOS memprosesnya di server Apple.

## Membangun & menjalankan

Butuh Xcode (atau Command Line Tools) dengan Swift 5.9+, dan environment conda `meeting` dari versi 1.x.

```bash
cd ~/coba/coba
git pull
conda activate meeting
pip install -r requirements.txt
./mac/build.sh
open mac/build/MeetingNotes.app
```

Pertama kali dibuka, macOS akan meminta izin:

1. **Microphone**: klik *Allow*.
2. **Speech Recognition**: klik *Allow* (untuk transkrip live).
3. **Screen & System Audio Recording**: buka System Settings → Privacy & Security → Screen & System Audio
   Recording → aktifkan **Meeting Notes**, lalu keluar dari aplikasi (ikon gelombang di menu bar → Keluar) dan
   buka lagi. Tanpa izin ini, aplikasi tetap merekam lewat mic saja.

> Setiap kali `build.sh` dijalankan ulang, macOS bisa meminta izin lagi karena aplikasinya ditandatangani
> secara lokal. Itu normal.

## Agar terbuka otomatis saat login

System Settings → General → Login Items → **+** → pilih `mac/build/MeetingNotes.app`.

## Jika bermasalah

| Gejala | Coba |
|---|---|
| `build.sh` gagal di langkah `swift build` | Kirim 20 baris terakhir pesan galatnya |
| Widget menulis "Audio Zoom/Meet/Teams belum terekam" | Berikan izin Screen & System Audio Recording, lalu buka ulang aplikasi |
| "Python tidak ditemukan" | Jalankan ulang `./mac/build.sh` setelah `conda activate meeting` |
| Gagal memproses | Rekaman aman di `~/MeetingNotes/rekaman/<waktu>/meeting.wav`; proses ulang dengan `python -m meeting_notes proses <file>` |
