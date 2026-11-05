# Meeting Notes untuk Mac (4.0.0)

Aplikasi menu bar dengan "pulau" ala Dynamic Island di tengah atas layar. Alurnya seperti OBS + notulis:
**rekam rapat (video layar + suara) → stop → transkrip → MoM otomatis.**

| Status | Tampilan |
|---|---|
| Siap | Kapsul kecil; klik untuk tombol **Mulai**, chip **Word** dan **Video** |
| Merekam | Titik merah, timer, chip jalur suara (🎤 mic & 👥 peserta), kartu info (apa yang direkam, sisa disk dalam menit rekaman), **Penting**, tombol stop |
| Memproses | *Mentranskrip (persen) → Menyusun MoM* |
| Selesai | Judul rapat, jumlah keputusan & tugas, tombol **Buka MoM**, **Salin**, **Putar video**, **Folder** |

Shortcut global **⌃⌥M** (Control + Option + M) untuk mulai/berhenti dari aplikasi mana pun.

Menu bar (ikon gelombang): Mulai/Selesai, Buka folder notulen, **Buat juga Word (.docx)**, sumber video
(**seluruh layar / jendela Teams saja / jendela Zoom saja / tidak direkam**), Audio meeting via Core Audio
(eksperimental), Peredam derau mic, bentuk pulau (Island / Pill), dan Keluar.

## Cara kerja

- **Aplikasi Swift (folder ini)** merekam selama rapat, ringan untuk Mac 8 GB:
  - `mic.wav` (suaramu) dan `sistem.wav` (suara peserta Zoom/Meet/Teams) terpisah, plus `meeting.wav`
    (campuran), lewat ScreenCaptureKit (tanpa BlackHole, tetap jalan saat pakai headphone);
  - `layar.mov`: video 720p 30 fps (H.264, ±1 GB per jam) berisi layar, suara peserta, dan suara mic
    (macOS 15+). Jendela Meeting Notes sendiri tidak ikut terekam. Gagal merekam video tidak pernah
    menghentikan rekaman audio.
  - Sisa disk dipantau: peringatan bila sisa < 30 menit rekaman; bila < 10 menit, video dihentikan agar audio
    untuk notulen tetap terekam sampai selesai.
- **"Otak" Python (folder `meeting_notes`)**: setelah tombol stop, aplikasi menjalankan
  `python -m meeting_notes proses` untuk transkripsi Whisper per jalur ("Saya (mic)" / "Peserta online"),
  koreksi Claude, kamus, dan MoM. Rapat 1 jam di M1 8 GB: perkiraan ±5–12 menit sampai MoM jadi; notifikasi
  muncul saat selesai.

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
2. **Screen & System Audio Recording** (video layar dan suara peserta Zoom/Meet/Teams): buka System Settings → Privacy &
   Security → Screen & System Audio Recording → aktifkan **Meeting Notes**, lalu keluar dari aplikasi (ikon
   gelombang di menu bar → Keluar) dan buka lagi. Tanpa izin ini, aplikasi tetap merekam lewat mic saja.
   Pilihan eksperimental **Audio meeting via Core Audio** (menu bar, mati secara bawaan) butuh izin di bagian
   **System Audio Recording Only**; bila tap hening, aplikasi otomatis kembali ke rekam layar.

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
| Rekaman hening / "Tidak ada suara yang terdeteksi" / pulau menulis "Mic hanya memberi hening" | `killall MeetingNotes; ./mac/build.sh --reset-izin`, buka app, izinkan Microphone & Speech Recognition, nyalakan Meeting Notes di Screen & System Audio Recording, buka ulang app. Lihat `rekaman.log` di folder rekaman (puncak 0 = hening total) |
| Memproses terlalu lama / macet | Klik ✕ di pulau untuk membatalkan (rekaman aman), lalu **Proses ulang** |
| Chip 👥 **Peserta** tidak pernah menyala / "Suara peserta belum terdengar sama sekali" | Izinkan Meeting Notes di **System Audio Recording Only** (lihat Izin). Pastikan **Audio meeting via Core Audio (eksperimental)** di menu bar tidak dicentang, izinkan Meeting Notes di **Screen & System Audio Recording**, keluar lalu buka lagi app. Cek baris `Audio sistem` di `rekaman.log` |
| "Gagal mulai merekam" / "Mic gagal menyala" (mis. kode -10875) | Klik **Coba lagi**. Bila berulang: matikan **Peredam derau mic** di menu bar, tutup aplikasi lain yang mengunci mic, cek System Settings → Sound → Input. Detail percobaan ada di `rekaman.log` |
| Ruangan bising / suara mic kurang jelas | Menu bar → **Peredam derau mic** (berlaku untuk rekaman berikutnya) |
| Video tidak ada / "Video tidak terekam" | Izinkan Meeting Notes di **Screen & System Audio Recording**, keluar lalu buka lagi app. Pilihan "jendela Teams/Zoom" butuh jendelanya terbuka (tidak diminimalkan) saat mulai merekam; bila tidak ketemu, seluruh layar yang direkam |
| "Disk hampir penuh" | Kosongkan ruang disk (hapus `layar.mov` rapat lama di `~/MeetingNotes/rekaman/`; transkrip & MoM tetap tersimpan) |
| Kartu "MoM belum tersusun" (mis. batas pemakaian Claude) | Klik **Susun ulang**: transkrip yang tersimpan dipakai, tanpa mentranskripsi ulang |
| Aplikasi tertutup paksa / Mac mati saat merekam | Rekaman tetap bisa diproses: `python -m meeting_notes proses ~/MeetingNotes/rekaman/<waktu>/meeting.wav` |
