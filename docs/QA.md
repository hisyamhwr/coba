# QA sebelum masuk versi 2.0.0

## Sudah diuji otomatis (di server, Linux)

| Area | Hasil |
|---|---|
| 22 unit test (ekspor, pemotongan audio, paragraf, halusinasi, koreksi, kamus, pipeline, summarizer) | ✅ Lulus |
| Koreksi + MoM dengan Claude sungguhan (Claude Code), transkrip berisi "PoIP"/"girlfriend"/"back and" | ✅ Semua terkoreksi, kamus terisi 11 istilah |
| Widget di layar virtual: siap → merekam → selesai, mikrofon gagal, pemrosesan gagal | ✅ (setelah perbaikan 1.1.1) |

## Temuan QA di Mac

| Versi | Temuan | Status |
|---|---|---|
| 1.1.1 | Saat diam, transkrip mengulang "mengalokasikan dan" puluhan kali | ✅ Diperbaiki di 1.1.2 |
| 1.1.1 | "store turner" dikoreksi jadi "store tertentu", seharusnya "setor tunai" | ✅ Diperbaiki di 1.1.2 (diuji dengan 5 salah dengar baru: semuanya benar) |
| 1.1.1 | Koreksi menambah kata yang tidak diucapkan ("POS. Lalu POS mengirimkan") | ✅ Diperbaiki di 1.1.2 |

## Belum bisa diuji di server, wajib dicek di Mac

Server tidak punya mikrofon, tidak bisa mengunduh model Whisper, dan bukan Mac. Hal berikut **hanya** bisa
dibuktikan di MacBook-mu:

| # | Skenario | Cara cek | Yang diharapkan |
|---|---|---|---|
| 1 | Update | `git pull` lalu `pip install -r requirements.txt` | Tidak ada error; `mlx-whisper` terpasang |
| 2 | Unduh model | Buka widget, tunggu ±5-10 menit pertama kali | Judul jendela `Meeting Notes v1.1.2`, tidak ada pesan gagal unduh |
| 3 | Rapat pendek (5 menit) | Ngobrol pakai istilah kantor (VoIP, frontend, Daily Banking) | Transkrip jauh lebih akurat dari 1.0.1 |
| 4 | Kecepatan | Catat lama proses setelah klik **Selesai** untuk rapat 5 menit | Idealnya < 1-2 menit |
| 5 | Kamus belajar | Lakukan rapat kedua, buka `~/MeetingNotes/kamus.txt` | Berisi istilah dari rapat pertama |
| 6 | Rapat panjang (≥ 1 jam) | Pakai rapat sungguhan | Status "Mentranskrip... x%" bergerak, Mac tidak hang, MoM per agenda |
| 7 | Meeting online | Zoom/Meet pakai **speaker** (bukan headphone) | Suara peserta lain ikut tertranskrip |
| 8 | File lama | `python -m meeting_notes proses <file .m4a/.mp3>` | Notulen jadi |

Laporkan hasilnya per nomor (✅ / ❌ + screenshot). Bug yang ditemukan diperbaiki sebagai 1.1.2, 1.1.3, dst.
Setelah semua ✅, kita masuk ke 2.0.0.
