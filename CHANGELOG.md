# Changelog

Format versi: `MAYOR.FITUR.PERBAIKAN` (lihat [docs/ROADMAP.md](docs/ROADMAP.md)).

## 3.0.0

Siap untuk rapat panjang (1 jam lebih): audit menyeluruh, perbaikan bug, dan peningkatan akurasi. Tetap 100%
lokal dan gratis (tanpa cloud).

**Akurasi transkrip**
- **Perbaikan besar:** petunjuk istilah (kamus, FE, flagging, ...) sebelumnya hanya dipakai Whisper untuk
  30 detik pertama setiap potongan audio (perilaku mlx-whisper dengan `condition_on_previous_text=False`), jadi
  75–95% audio ditranskripsi tanpa petunjuk. Kini audio dipotong sendiri per ≤ 28 detik di titik jeda, dan
  setiap jendela mendapat petunjuk lengkap plus akhir kalimat jendela sebelumnya agar konteksnya bersambung.
- Audio meeting tidak lagi "patah-patah": data audio dari Zoom/Teams yang datang tidak rata kini diberi
  cadangan 250 ms. Sebelumnya setiap keterlambatan kecil diisi hening di tengah ucapan.
- Campuran mic + meeting tidak lagi pecah (clipping) saat keduanya keras bersamaan.
- Transkripsi latar belakang memakai Mac lebih ringan (turun ke model turbo bila memakan > 40% waktu) agar
  Zoom/Teams tetap lancar, dan tidak berhenti bila sesekali error.

**Transkrip live**
- Bug: jeda hening pertama membuat transkrip live permanen memakai pengenal online (lebih lambat). Diperbaiki.
- Sesi pengenal suara diganti pada jeda bicara (setelah 40 detik, paling lambat 55 detik), tidak lagi tepat di
  detik ke-50 di tengah kalimat; kata yang sedang dikenali tidak hilang dan tidak tercatat dua kali saat ganti.

**MoM**
- Bagian baru **Risiko & Blocker**.
- Action item lebih rapi: diawali kata kerja, satu tugas per item, tugas duplikat digabung.
- Instruksi agar keputusan/penugasan di bagian akhir rapat panjang tidak terlewat.
- Bila Claude gagal (jaringan, batas pemakaian), dicoba sekali lagi otomatis. Bila tetap gagal, kartu
  menampilkan alasannya dengan tombol **Susun ulang** yang langsung menyusun MoM dari transkrip yang tersimpan
  (`transkrip_final.json`), tanpa mentranskripsi ulang.
- Tabel MoM tidak lagi rusak bila teks berisi `|` atau baris baru.

**Keandalan rapat panjang**
- Menutup aplikasi saat merekam kini menutup file rekaman dengan rapi.
- Rekaman yang tidak sempat ditutup (aplikasi tertutup paksa, Mac mati) tetap bisa diproses: header WAV yang
  rusak tidak lagi membuat rekaman terbaca kosong.
- Mic yang berhenti diam-diam (mis. setelah Mac tidur) dipasang ulang otomatis dalam ±4 detik.
- Timer dan waktu **Penting** memakai jam audio (selalu cocok dengan rekaman) dan tetap berjalan saat menu bar
  dibuka.
- Tombol batal saat memproses; disk penuh dilaporkan saat merekam.
- Proses akhir membaca audio per potongan langsung dari file: memori puncak rapat 70 menit turun dari ±770 MB
  ke ±230 MB (diuji dengan simulasi rapat 70 menit; sisa audio yang ditranskripsi setelah rapat selesai ±85
  detik).

**Diuji dengan Claude sungguhan** pada transkrip realistis rapat sprint 70 menit (±7.700 kata, penuh salah dengar
ASR): MoM selesai dalam 55 detik dengan 22 koreksi istilah (tidak ada salah dengar yang tersisa), 10 keputusan,
42 action item lengkap dengan PIC dan tenggat, 14 risiko/blocker, dan momen penting di menit yang ditandai.

## 2.3.4

- **Transkrip live lebih real time dan tidak terpotong.**
  - Kata terakhir sebelum jeda kini selalu tampil. Sebelumnya bisa tertahan pembatas update.
  - Update hingga ±7x per detik.
  - Teks panjang dipotong di depan ("…"), bukan di kanan, sehingga ucapan terbaru selalu terlihat.
  - Kata yang masih dikenali tampil kuning-oranye, lalu berubah putih begitu final.
  - Istilah dari kamus (FE, deploy, flagging, ...) diberikan ke pengenal suara macOS agar lebih tepat.
- **Huruf lebih ringan dan estetik:** SF Pro regular untuk transkrip dan teks, SF Pro Rounded medium/semibold
  untuk judul dan angka (sebelumnya banyak yang tebal).
- **Lebih modern, ceria, dan hidup** (tetap ringan):
  - gradien identitas pink-oranye-kuning dan equalizer warna-warni;
  - logo memantul dan miring saat disorot; tombol terangkat saat disorot;
  - penghitung momen penting "meletup";
  - titik "sedang menulis" saat menyusun MoM; garis progres dengan kepala bercahaya;
  - centang tergambar disertai semburan konfeti saat MoM siap.

## 2.3.3

Animasi lebih mulus dan ringan:

- Cahaya di dalam pulau tidak lagi digambar ulang setiap frame saat pulau melebar/menyusut (disusun pada
  ukuran akhir); kekuatan cahaya dan denyut mengikuti suara kini lewat opacity lapisan, bukan menggambar ulang
  gradien.
- Garis cahaya berputar saat memproses (paling berat: gradien besar dirender ulang setiap frame) diganti garis
  tepi bergradien yang "bernapas".
- Bayangan pada tombol Mulai dan Stop (blur mahal, dihitung ulang saat beranimasi) diganti cahaya gradien statis.
- Pudar pada transkrip live memakai gradien warna teks, bukan mask (mask memaksa render tambahan setiap frame).
- Proses Python (Whisper & Claude) berjalan dengan prioritas di bawah tampilan.

## 2.3.2

Ikon dan animasi lebih hidup, tetap ringan. Sistem desain didokumentasikan di [docs/DESIGN.md](docs/DESIGN.md).

- **Ikon baru:**
  - logo bola bergradien pink-oranye dengan gelombang suara putih, memantul saat disorot;
  - tombol Mulai dengan ikon rekam ala kamera;
  - lencana centang yang "tergambar" lalu beriak saat MoM siap.
- **Animasi baru:**
  - equalizer 5 batang bergradien yang mengikuti suaramu;
  - garis cahaya warna-warni berputar mengelilingi pulau saat Claude memproses;
  - riak saat menekan **Penting**;
  - angka bergulir pada penghitung;
  - ikon berganti dengan efek sistem;
  - getaran halus trackpad saat mulai, menandai, selesai, dan menyalin.
- **Lebih mulus dan ringan:**
  - pegas animasi disetel ulang;
  - selama rapat tidak ada animasi yang berjalan terus-menerus: equalizer dan cahaya hanya bergerak saat level
    suara berubah (maks. ±12x per detik);
  - animasi kontinu hanya saat memproses, dirender lewat GPU;
  - bayangan pada titik rekam yang berdenyut dihapus.
- **Aksesibilitas:** semua animasi dekoratif mati bila Reduce motion aktif; tombol ikon punya label VoiceOver.

## 2.3.1

- **Tampilan pulau lebih mencolok dan bersih**, mengikuti referensi desain:
  - Cahaya warna di dalam pulau sesuai status: merah-oranye saat merekam (ikut berdenyut mengikuti suara),
    biru-ungu saat memproses, hijau saat MoM siap.
  - Tombol besar **Mulai catat** bergradien.
  - Transkrip live lebih besar, dengan baris lama memudar ke atas.
  - Tombol stop bercahaya; tombol **Penting** dengan penghitung.
  - Memproses: satu garis progres dengan persentase nyata saat mentranskrip.
  - Kartu hasil: judul besar, ringkasan keputusan/tugas/momen penting dalam kapsul, dan tombol ikon
    (Salin berubah jadi ✓ sesaat setelah diklik).
- **Teks yang tidak perlu dihapus** dari pulau: versi, shortcut, nama mic, detail langkah, dan label "Meeting
  Notes". Pilihan Word kini berupa kapsul kecil "Word". Menu bar juga tidak lagi menampilkan shortcut.

## 2.3.0

Optimasi: lebih akurat tanpa menunggu lebih lama, tanpa perlu memilih mode. Pilihan "Mode akurat" dari 2.2.0
dihapus dari aplikasi.

- **Transkripsi di latar belakang selama rapat.**
  - Saat mulai merekam, aplikasi menjalankan `python -m meeting_notes ikuti`, yang mentranskripsi setiap
    potongan ±2 menit begitu lengkap.
  - Prosesnya berprioritas rendah agar Zoom/Teams tetap lancar.
  - Setelah rapat selesai, hanya sisa ±2 menit terakhir yang perlu ditranskripsi, berapa pun panjang rapatnya.
  - Hasil disimpan per potongan (`transkrip_parsial.json`), jadi aman bila proses terhenti.
- **Model dipilih otomatis.**
  - Mac Apple Silicon dengan RAM ≥ 16 GB memakai Whisper large-v3 penuh, yang paling akurat untuk bicara
    cepat/belibet. Lambatnya tidak terasa karena berjalan selama rapat.
  - Mac lain memakai large-v3-turbo.
  - Bila Mac tidak sanggup mengejar rapat, otomatis turun ke turbo.
  - Proses ulang rekaman panjang (> 10 menit sisa) memakai turbo agar tetap cepat.
  - Pertama kali, model large-v3 (±3 GB) diunduh di latar belakang saat rapat.
- **Hening dipangkas sebelum Whisper.** Jeda > 1,5 detik dibuang dan waktu dipetakan kembali, sehingga
  transkripsi lebih cepat (terutama jalur mic saat kamu lebih banyak mendengarkan) dan halusinasi berkurang.
- **MoM jauh lebih cepat.**
  - Claude Code memakai Sonnet dengan effort medium.
  - Diuji pada transkrip 1 jam (±10.000 kata): ±25 detik, sebelumnya ±4 menit.
  - Agenda, action item, dan semua uji koreksi istilah developer tetap benar.
  - Bisa diubah lewat `CLAUDE_CODE_MODEL` / `CLAUDE_CODE_EFFORT` di `.env`.

## 2.2.0

- **Mode akurat** untuk pembicara yang cepat atau belibet:
  - Aktifkan dengan centang di pulau, di menu bar, atau lewat `proses --akurat`.
  - Memakai Whisper large-v3 penuh (32 lapis decoder; turbo hanya 4).
  - Konsekuensi: ±3x lebih lambat, dan pertama kali mengunduh model ±3 GB.
- Istilah baru: bundling, fetch, UI/UX, push, rebase, revert, cherry-pick, conflict, hit API, dll.
- Claude mengenali kata kerja Inggris ber-awalan Indonesia yang salah tangkap:
  - "dibanding" → "di-bundling" bila membahas aset/paket (tetap "dibanding" bila artinya membandingkan);
  - "di fes" → "di-fetch", "yu ai yu eks" → "UI/UX";
  - kata yang tidak masuk akal seperti "direpost" ditebak dari konteks, mis. "di-revert".
  - Diuji dengan Claude sungguhan: semua benar, tidak ada regresi pada uji 2.1.0, tidak ada koreksi keliru di
    rapat non-teknis.
- Prompt Whisper: istilah terpenting ditaruh paling dekat ke akhir, karena Whisper hanya membaca ±223 token
  terakhir dari prompt.

## 2.1.0

Istilah developer dan kualitas tangkapan suara.

- **Istilah developer dan produk digital.**
  - Kamus dasar kini ±220 istilah. Istilah developer ditaruh paling atas: frontend/backend, FE, BE, DS,
    flagging/feature flag, PR, merge, deploy, staging, SIT, UAT, pentest, sprint, story point, Jira, Figma,
    SwiftUI, Jetpack Compose, React Native, BRImo, Tabungan Rencana, dll.
  - Whisper diberi contoh kalimat rapat developer. Whisper meniru ejaan dari contoh, jadi singkatan seperti
    FE/BE/PR lebih sering tertulis benar. Contoh ini diletakkan di akhir prompt agar tidak terpotong.
  - Claude mengenali salah dengar khas developer: "legging" → "flagging", "bek en" → "backend",
    "diploi" → "deploy", "ripiu" → "review".
  - Claude juga menggabungkan singkatan yang dieja dengan huruf Indonesia: "ef e" → FE, "de es" → DS,
    "pe er" → PR, "kiu e" → QA, "esite" → SIT.
  - Diuji dengan Claude sungguhan: 11/11 salah dengar terkoreksi, dan tidak ada koreksi keliru pada rapat
    non-teknis (mis. "legging" sebagai pakaian).
- **Rekaman dua jalur.**
  - Aplikasi Mac menyimpan `mic.wav` (suaramu) dan `sistem.wav` (suara Zoom/Teams/Meet) di samping `meeting.wav`.
  - Whisper lokal mentranskripsi tiap jalur terpisah:
    - suara meeting yang jernih tidak lagi tercampur derau ruangan dari mic;
    - suaramu yang lebih pelan dikuatkan tersendiri;
    - transkrip berlabel **"Saya (mic)"** dan **"Peserta online"**, sehingga MoM tahu siapa yang meminta dan
      siapa yang menyanggupi.
  - Suara speaker yang ikut tertangkap mic dibuang agar tidak tercatat dua kali.
  - Rapat offline (jalur meeting hening) tetap memakai satu jalur seperti sebelumnya.
  - Konsekuensi: waktu transkripsi rapat online bisa sampai dua kali lebih lama.

## 2.0.10

- Transkrip live: error pengenal suara macOS tidak lagi didiamkan (sebelumnya pulau hanya menulis
  "Mendengarkan…"). Sesi dibuka ulang otomatis, beralih ke pengenal online Apple bila pengenal di perangkat
  gagal, dan bila tetap gagal pulau menampilkan penyebabnya (mis. Dictation mati, izin Speech Recognition).
- Audio meeting dipasang ulang otomatis bila macOS menghentikannya, mis. saat output pindah ke headset.
- `rekaman.log`: satu baris per 10 detik berisi level mic dan audio meeting, pergantian perangkat audio, dan
  error transkrip live.

## 2.0.9

- Mulai merekam tidak lagi tertahan menunggu izin Screen & System Audio Recording: mic langsung merekam dan timer
  berjalan; audio meeting menyusul. Sebelumnya pulau bisa diam di "Meeting Notes" tanpa merekam apa pun.
- Pulau menampilkan "Menyiapkan..." selama menyiapkan rekaman, dan "Menunggu izin ..." bila audio meeting belum
  diizinkan setelah 4 detik.
- `rekaman.log` mencatat setiap langkah (klik Mulai, izin mic, mic mulai, audio sistem mulai/gagal, ringkasan).

## 2.0.8

- Perbaikan rekaman hening (suara sendiri dan peserta meeting tidak terekam): izin Microphone dan Screen & System
  Audio Recording macOS terikat ke biner lama setiap kali app di-build ulang, sehingga izin tampak aktif tetapi
  macOS hanya memberi hening. `build.sh` kini menandatangani app dengan bundle ID agar izin tetap berlaku, mereset
  izin lama sekali, dan punya opsi `--reset-izin`.
- Pulau memperingatkan bila mic hanya memberi hening total selama 3 detik pertama.
- Mic dipasang ulang otomatis bila perangkat berganti di tengah rapat (AirPods, Zoom mengubah format mic);
  sebelumnya sisa rekaman menjadi hening.
- Audio sistem dibaca sesuai format aslinya.
- `rekaman.log` di folder rekaman: nama/format mic, izin, puncak level mic dan audio sistem, untuk diagnosis.

## 2.0.7

- `build.sh` memeriksa library Python (soundfile, faster-whisper, dll.) pada Python yang dipakai aplikasi dan
  memasangnya otomatis bila belum ada. Sebelumnya library bisa terpasang di Python lain (conda "base") sehingga
  aplikasi gagal dengan `No module named 'soundfile'`.
- Kartu "Gagal memproses" punya tombol **Proses ulang** untuk rekaman yang sama.

## 2.0.6

- Transkrip live tetap aktif secara default dan lebih ringan: update teks dibatasi ±4x per detik (hasil akhir
  selalu langsung tampil) dan tanpa animasi tata letak per update.

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
