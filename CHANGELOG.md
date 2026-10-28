# Changelog

Format versi: `MAYOR.FITUR.PERBAIKAN` (lihat [docs/ROADMAP.md](docs/ROADMAP.md)).

## 2.0.5

- Aplikasi Mac: bila pemrosesan gagal, pulau menampilkan inti error (baris terakhir) yang bisa diseleksi/disalin,
  dan log lengkap disimpan ke `proses.log` di folder rekaman.
- Python dijalankan seperti setelah `conda activate` (PATH dan CONDA_PREFIX environment).

## 2.0.4

- Animasi lebih mulus dan responsif:
  - klik pulau langsung melebar (sebelumnya menunggu 0,12 detik efek tekan);
  - pegas lebih cepat (response 0,38) dengan pantulan halus;
  - isi pulau disusun sekali pada ukuran akhirnya, bukan disusun ulang tiap frame selama animasi;
  - efek blur (mahal) diganti fade + skala ringan; isi baru muncul sesaat setelah bentuk mulai melebar.
- Lebih ringan: gelombang suara dan titik rekam memakai efek simbol bawaan macOS (dirender sistem), bukan
  animasi per frame; SwiftUI tidak lagi menghitung ulang batas ukuran jendela setiap isi berubah.

## 2.0.3

- Animasi "liquid" ala Dynamic Island: pulau tumbuh dari titik kecil saat muncul, berubah bentuk dengan pegas
  yang sedikit memantul, isi berganti dengan efek blur, sedikit menggembung saat kursor di atasnya, efek tekan
  saat diklik, titik rekam yang "bernapas", dan timer dengan angka bergulir.
- Lebih ringan: jendela tidak lagi diubah ukurannya (hanya bentuk di dalamnya yang beranimasi); timer, level
  suara, dan transkrip live dipisah sehingga hanya komponen kecilnya yang digambar ulang; update level suara
  dikirim hanya bila berubah; gelombang suara dibatasi ±20 fps.
- Klik di area transparan sekitar pulau tembus ke aplikasi di bawahnya; posisi pulau menyesuaikan saat layar
  berubah.
- Menu bar: **Transkrip live** bisa dimatikan untuk menghemat CPU/baterai (diingat antar sesi).

## 2.0.2

- Word (.docx) kini opsional: centang **"Buat juga Word (.docx)"** di aplikasi Mac (pulau atau menu bar) atau di
  widget Python. Default hanya Markdown (.md). Pilihan di aplikasi Mac diingat antar sesi.
- `proses --docx` dan `EXPORT_DOCX=true` di `.env` untuk baris perintah.
- **Buka MoM** membuka .docx bila dibuat, selain itu file .md.

## 2.0.1

- Aplikasi Mac: perbaikan kompilasi Swift 6.4 (isolasi main actor di titik masuk aplikasi dan inisialisasi,
  panggilan notifikasi yang ambigu).
- `build.sh`: bila build gagal, hanya baris error yang ditampilkan; log lengkap di `mac/build/swift-build.log`.

## 2.0.0

- **Aplikasi Mac native** (`mac/`): aplikasi menu bar dengan "pulau" ala Dynamic Island di tengah atas layar,
  tanpa terminal. Status siap, merekam (ringkas/diperluas), memproses, selesai, dan gagal.
- Rekam mic + **audio Zoom/Meet/Teams secara digital** lewat ScreenCaptureKit, tanpa BlackHole dan tetap jalan
  saat memakai headphone; keduanya digabung menjadi satu rekaman.
- **Transkrip live** (pengenal suara macOS, bahasa Indonesia) di pulau notch.
- Tombol **Tandai penting**: momen yang ditandai menjadi bagian "Momen Penting" di MoM.
- Shortcut global ⌃⌥M, notifikasi saat MoM siap, tombol Buka MoM / Salin / Folder.
- Python: `proses --json --penting --mulai` untuk aplikasi Mac; skema MoM menambah `highlights`.

## 1.3.0

- Kamus dasar bawaan (±130 istilah perbankan, produk digital, dan IT) dipakai sejak rapat pertama, setelah
  istilah yang dipelajari dari rapatmu. Diuji: Claude tidak memaksakan istilah ini pada rapat non-perbankan.
- Suara yang terlalu pelan (mic jauh) otomatis dikuatkan sebelum ditranskripsi Whisper lokal.
- Widget menampilkan mic yang sedang dipakai ("Mendengarkan via ...").
- README: tips audio untuk akurasi terbaik.

## 1.2.0

- Mesin transkripsi cloud: ElevenLabs Scribe v2, AssemblyAI Universal-3.5 Pro, Deepgram Nova-3
  (`TRANSCRIPTION_ENGINE`), dengan kamus otomatis sebagai keyterms dan cadangan otomatis ke Whisper lokal.
- Label pembicara ("Pembicara 1, 2, ...") dari mesin cloud, di transkrip dan untuk MoM.
- Perintah `bandingkan`: uji tanding semua mesin pada potongan rekaman yang sama, hasil berdampingan di browser.
- Widget: pesan gagal unduh model tidak lagi menimpa pesan "Tersimpan".

## 1.1.2

- Transkrip: frasa yang terulang-ulang saat pembicara diam ("mengalokasikan dan mengalokasikan dan ...")
  diringkas menjadi satu, dan Whisper melewati bagian sunyi yang memicu halusinasi.
- Koreksi: Claude mengutamakan kemiripan bunyi dan topik rapat (mis. "store turner" → "setor tunai",
  bukan "store tertentu"), dan tidak lagi menambahkan kata yang tidak diucapkan.

## 1.1.1

- Widget: gagal mengunduh model Whisper tidak lagi menimpa status "Mendengarkan rapat...".
- Widget: jika pemrosesan gagal, rekaman tetap aman dan tombol **Buka folder rekaman** muncul.
- MoM: penugasan tidak lagi ikut tertulis sebagai keputusan.
- MoM: orang yang hanya disebut namanya tidak lagi dicatat sebagai peserta.

## 1.1.0

- Claude otomatis mengoreksi kata yang salah dengar (mis. "girlfriend" → "frontend", "PoIP" → "VoIP").
- Kamus istilah yang belajar sendiri (`~/MeetingNotes/kamus.txt`) dan dipakai Whisper serta Claude di rapat berikutnya.
- Lampiran "Koreksi Otomatis" di notulen.

## 1.0.2

- Whisper `large-v3-turbo`, berjalan di GPU Mac (MLX) pada Mac M1/M2/...
- Transkripsi per potongan ±10 menit, bagian sunyi dilewati, halusinasi Whisper dibuang.
- Transkrip dirapikan menjadi paragraf dan dipindah ke lampiran.
- MoM baru: ringkasan eksekutif, keputusan utama, action items bernomor, pembahasan per agenda dengan waktu mulai.
- PyAV dikunci di bawah versi 19 karena versi 19 merusak pembacaan audio.

## 1.0.1

- MVP: widget, rekam mikrofon + audio sistem, transkripsi lokal, ringkasan via Claude Pro (Claude Code) atau API, ekspor .md dan .docx.
