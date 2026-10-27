# QA sebelum masuk versi 2.0.0

## Sudah diuji otomatis (di server, Linux)

| Area | Hasil |
|---|---|
| 34 unit test (termasuk mesin cloud dengan respons tiruan) (ekspor, pemotongan audio, paragraf, halusinasi, koreksi, kamus, pipeline, summarizer) | ✅ Lulus |
| Koreksi + MoM dengan Claude sungguhan (Claude Code), transkrip berisi "PoIP"/"girlfriend"/"back and" | ✅ Semua terkoreksi, kamus terisi 11 istilah |
| Widget di layar virtual: siap → merekam → selesai, mikrofon gagal, pemrosesan gagal | ✅ (setelah perbaikan 1.1.1) |

## Temuan QA di Mac

| Versi | Temuan | Status |
|---|---|---|
| 1.1.1 | Saat diam, transkrip mengulang "mengalokasikan dan" puluhan kali | ✅ Diperbaiki di 1.1.2 |
| 1.1.1 | "store turner" dikoreksi jadi "store tertentu", seharusnya "setor tunai" | ✅ Diperbaiki di 1.1.2 (diuji dengan 5 salah dengar baru: semuanya benar) |
| 1.1.1 | Koreksi menambah kata yang tidak diucapkan ("POS. Lalu POS mengirimkan") | ✅ Diperbaiki di 1.1.2 |
| 1.1.2 | Transkrip Whisper lokal masih banyak salah (artikulasi kurang jelas) | ➡️ 1.2.0: mesin cloud (opsional); 1.3.0: kamus dasar, penguat suara, tips mic |

## Belum bisa diuji di server, wajib dicek di Mac

Server tidak punya mikrofon, tidak bisa mengunduh model Whisper, dan bukan Mac. Hal berikut **hanya** bisa
dibuktikan di MacBook-mu:

| # | Skenario | Cara cek | Yang diharapkan |
|---|---|---|---|
| 1 | Update | `git pull` lalu `pip install -r requirements.txt` | Tidak ada error; `mlx-whisper` terpasang |
| 2 | Unduh model | Buka widget, tunggu ±5-10 menit pertama kali | Judul jendela `Meeting Notes v1.3.0`, tidak ada pesan gagal unduh |
| 3 | Rapat pendek (5 menit) | Ngobrol pakai istilah kantor (VoIP, frontend, setor tunai), **pakai earphone ber-mic** | Widget menulis "Mendengarkan via <earphone>"; transkrip lebih akurat dari sebelumnya |
| 4 | Kecepatan | Catat lama proses setelah klik **Selesai** untuk rapat 5 menit | Idealnya < 1-2 menit |
| 5 | Kamus belajar | Lakukan rapat kedua, buka `~/MeetingNotes/kamus.txt` | Berisi istilah dari rapat pertama |
| 6 | Rapat panjang (≥ 1 jam) | Pakai rapat sungguhan | Status "Mentranskrip... x%" bergerak, Mac tidak hang, MoM per agenda |
| 7 | Meeting online | Zoom/Meet pakai **speaker** (bukan headphone) | Suara peserta lain ikut tertranskrip |
| 8 | File lama | `python -m meeting_notes proses <file .m4a/.mp3>` | Notulen jadi |
| 9 | **Uji tanding** | `python -m meeting_notes bandingkan <rekaman> --mulai 60 --durasi 300` | Laporan berdampingan terbuka di browser; pilih pemenang |
| 10 | Mesin pemenang | Isi `TRANSCRIPTION_ENGINE` di `.env`, lakukan rapat | Transkrip berlabel "Pembicara 1, 2", akurasi sesuai uji tanding |

Catatan: panggilan ke ElevenLabs/AssemblyAI/Deepgram belum pernah dijalankan sungguhan (server tidak bisa
menjangkau mereka dan tidak ada API key); format permintaan diambil dari dokumentasi/SDK resmi dan diuji dengan
respons tiruan. Jika salah satu mesin gagal di uji tanding, kirim pesan galatnya.

Laporkan hasilnya per nomor (✅ / ❌ + screenshot). Bug yang ditemukan diperbaiki sebagai 1.1.2, 1.1.3, dst.
Setelah semua ✅, kita masuk ke 2.0.0.
