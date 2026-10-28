# QA

## QA 2.0.0: aplikasi Mac (wajib di Mac)

Kode Swift belum pernah di-compile (server tidak punya macOS). Jalankan berurutan; berhenti dan kirim
pesan galat/screenshot di langkah pertama yang gagal. Bug diperbaiki sebagai 2.0.1, 2.0.2, dst.

| # | Langkah | Yang diharapkan |
|---|---|---|
| 1 | `conda activate meeting && ./mac/build.sh` (lihat [mac/README.md](../mac/README.md)) | Berakhir dengan "Selesai: mac/build/MeetingNotes.app" ✅ lulus di 2.0.1 (Swift 6.4, macOS 26) |
| 2 | `open mac/build/MeetingNotes.app` | Kapsul "Meeting Notes" muncul di tengah atas layar; ikon gelombang di menu bar |
| 3 | Klik kapsul → **Mulai Catat** | Diminta izin Microphone & Speech Recognition; lalu timer berjalan dan nama mic tampil |
| 4 | Bicara 1 menit | Transkrip live muncul dan ikut berubah; gelombang suara bergerak |
| 5 | Klik **Tandai penting** 2x | Chip menjadi "Tandai penting (2)" |
| 6 | Tekan ⌃⌥M | Rekaman berhenti, status berpindah ke "Memproses" |
| 7a | (Temuan 2.0.4–2.0.6) Pemrosesan gagal: `No module named 'soundfile'`; library terpasang di Python conda "base", bukan env `meeting` | 2.0.7: `build.sh` memasang library ke Python aplikasi; tombol **Proses ulang** |
| 7b | (Temuan 2.0.7) MoM jadi, tetapi rekaman hening: suara sendiri dan peserta meeting tidak terekam | 2.0.8: izin macOS tersangkut setelah build ulang → tanda tangan berbasis bundle ID, reset izin, peringatan hening, `rekaman.log` |
| 7c | (Temuan 2.0.8) Meeting Teams: pulau tetap "Meeting Notes" (tidak merekam), tidak ada transkrip live | 2.0.9: rekaman mic tidak lagi menunggu izin audio sistem; status "Menyiapkan..."; langkah tercatat di `rekaman.log` |
| 7 | Tunggu | Kartu "MoM siap" + notifikasi; **Buka MoM** membuka MoM (.md, atau .docx bila "Buat juga Word" dicentang) berisi "Momen Penting" |
| 8 | Izinkan Screen & System Audio Recording, buka ulang app, putar video YouTube sambil merekam **dengan headphone** | Suara video ikut tertranskrip di MoM |
| 9 | Meeting Zoom/Meet sungguhan ≥ 15 menit | Suara peserta lain dan suaramu tercatat; MoM per agenda |
| 10 | Klik di luar pulau / pindah Space / layar penuh | Pulau tetap di atas, tidak menghalangi kerja |

---

# QA 1.x

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
