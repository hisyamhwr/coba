# Meeting Notes Agent 🎙️

Widget kecil yang bisa kamu klik saat rapat: ia mendengarkan, mentranskripsi secara **lokal** di
laptopmu, lalu membuat notulen dalam **Bahasa Indonesia** (ringkasan, keputusan, action item, dan
transkrip lengkap) dalam format **Markdown (.md)** dan **Word (.docx)**.

Cocok untuk rapat online (Zoom, Google Meet, Teams) maupun offline. Agent ini tidak perlu ikut
join ke meeting, karena ia merekam langsung dari mikrofon dan speaker laptopmu.

```
 ┌────────────────────┐
 │       12:34        │   ● Mulai Catat         → mulai mendengarkan
 │  ▃▃▃▃▃▃▃▁▁▁▁▁▁▁▁   │   ■ Selesai & Rangkum   → transkripsi + ringkasan
 │ ■ Selesai & Rangkum│   Buka folder notulen   → lihat hasilnya
 │ Mendengarkan...    │
 └────────────────────┘
```

> **Baru di 2.0.0:** aplikasi Mac native dengan tampilan ala Dynamic Island, rekam audio Zoom/Meet/Teams
> langsung, transkrip live, dan tombol "Tandai penting". Lihat [mac/README.md](mac/README.md).
> Widget Python di bawah tetap bisa dipakai.

## Cara kerja

```
Mikrofon + audio speaker ──► rekaman WAV (lokal)
                               │
                               ▼
          Whisper large-v3-turbo (lokal, MLX di Mac M1) ──► transkrip
                               │
                               ▼
          Claude (langganan Pro/Max atau API) ──► ringkasan Bahasa Indonesia
                               │
                               ▼
                 ~/MeetingNotes/2026-10-27_0930_judul-rapat.md / .docx
```

- **Audio tidak pernah keluar dari laptopmu.** Rekaman dan transkripsi diproses sepenuhnya di perangkat.
- Yang dikirim ke Claude hanya **teks transkrip**, untuk dirangkum.
- Punya langganan **Claude Pro/Max**? Ringkasan dibuat lewat Claude Code dan memakai kuota
  langgananmu, **tanpa API key dan tanpa biaya tambahan**.

## Instalasi

Butuh **Python 3.10+** (dengan Tkinter, yang sudah termasuk di installer Python resmi untuk Windows & macOS).

```bash
git clone https://github.com/hisyamhwr/coba.git
cd coba
python -m venv .venv
# Windows: .venv\Scripts\activate    macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
```

Salin `.env.example` menjadi `.env`.

### Ringkasan dengan langganan Claude Pro/Max (tanpa API key)

Pasang Claude Code lalu login sekali dengan akun Claude Pro-mu:

```bash
curl -fsSL https://claude.ai/install.sh | bash   # atau: npm install -g @anthropic-ai/claude-code
claude                                            # pilih login dengan akun Claude, lalu ketik /exit
```

Selesai. Aplikasi otomatis memakai Claude Code untuk merangkum. Pemakaiannya dihitung dalam batas
kuota langganan Pro, sama seperti saat kamu chat di claude.ai.

### Atau dengan Claude API (berbayar per pemakaian)

Isi `ANTHROPIC_API_KEY` di `.env` (dapatkan di [console.anthropic.com](https://console.anthropic.com)).
Jika key diisi, mode `auto` akan memakai API.

> Linux: pasang juga `sudo apt install python3-tk` jika belum ada (butuh PulseAudio atau PipeWire).

## Pemakaian

```bash
python -m meeting_notes
```

1. Widget muncul dan selalu tampil di atas jendela lain.
2. Klik **● Mulai Catat** saat rapat dimulai.
3. Klik **■ Selesai & Rangkum** saat rapat selesai. Tunggu proses transkripsi dan ringkasan.
4. Klik **Buka folder notulen** untuk melihat file `.md` dan `.docx`.

Sudah punya rekaman (misalnya dari HP)? Proses langsung:

```bash
python -m meeting_notes proses rekaman-rapat.m4a
```

> Saat pertama dijalankan, model Whisper (~1,6 GB untuk `large-v3-turbo`) diunduh sekali di latar belakang. Setelah itu
> transkripsi berjalan tanpa internet.

## Isi notulen

1. Judul, tanggal, durasi, peserta
2. Ringkasan eksekutif (3-5 kalimat)
3. Keputusan utama
4. Action items (tugas, penanggung jawab, tenggat)
5. Pembahasan per agenda, lengkap dengan waktu mulai tiap topik
6. Pertanyaan terbuka
7. Lampiran: transkrip lengkap, dirapikan menjadi paragraf dan sudah dikoreksi
8. Lampiran: daftar koreksi otomatis (mis. "girlfriend" → "frontend")

## Transkrip makin akurat dengan sendirinya

Kamu tidak perlu mengisi kamus apa pun. Setiap selesai rapat:

1. Claude membetulkan kata yang salah dengar dari konteks, mis. "PoIP" → "VoIP".
2. Istilah penting dari rapat itu (nama orang, produk, istilah teknis) disimpan ke
   `~/MeetingNotes/kamus.txt`.
3. Di rapat berikutnya, kamus itu diberikan ke Whisper dan Claude sehingga istilahmu dikenali
   sejak awal.

`kamus.txt` adalah file teks biasa; boleh diedit manual bila ada istilah yang terus salah.

Sejak rapat pertama, aplikasi juga memakai **kamus dasar** bawaan (`meeting_notes/kamus_dasar.txt`):
±130 istilah perbankan, produk digital, dan IT yang sering salah dengar (setor tunai, nasabah, QRIS,
frontend, UAT, go-live, dll.). Istilah dari rapatmu sendiri selalu diprioritaskan di atasnya.

## Tips audio: paling berpengaruh ke akurasi

Akurasi transkrip paling ditentukan oleh **seberapa jelas suara masuk ke mikrofon**, bukan oleh software.

- **Pakai mic yang dekat ke mulut.** Earphone berkabel dengan mic, mic USB, atau mic clip-on jauh lebih
  jernih daripada mic laptop yang ikut menangkap gema ruangan dan suara ketikan.
- **Pilih mic-nya di Mac:** System Settings → Sound → Input → pilih earphone/mic eksternal. Saat merekam,
  widget menampilkan *"Mendengarkan via <nama mic>"*, jadi kamu bisa memastikan mic yang benar dipakai.
- **Rapat offline:** taruh laptop/mic di tengah meja, dekat dengan orang yang paling banyak bicara.
- **Meeting online tanpa headphone:** naikkan volume speaker secukupnya agar suara peserta lain
  tertangkap mic. Perekaman audio Zoom/Meet/Teams secara langsung (digital) hadir di versi 2.0.
- Aplikasi otomatis menguatkan suara yang terlalu pelan sebelum ditranskripsi, tapi tidak bisa
  menghilangkan gema atau suara bising; mic yang baik tetap paling berpengaruh.

## Transkripsi cloud (paling akurat untuk campuran Indonesia-Inggris)

Whisper lokal gratis dan offline, tetapi untuk bicara cepat atau artikulasi kurang jelas, mesin
cloud biasanya jauh lebih akurat. Pilihan yang didukung: **ElevenLabs Scribe v2**, **AssemblyAI
Universal-3.5 Pro**, dan **Deepgram Nova-3** (masing-masing ±$0,2-0,3 per jam audio; semuanya
punya kredit gratis untuk mencoba). Bonus: mesin cloud memberi label **Pembicara 1, 2, ...**

### 1. Uji tanding di rekamanmu sendiri

Isi API key yang ingin diuji di `.env` (`ELEVENLABS_API_KEY`, `ASSEMBLYAI_API_KEY`,
`DEEPGRAM_API_KEY`), lalu:

```bash
python -m meeting_notes bandingkan ~/MeetingNotes/rekaman/<folder>/meeting.wav --mulai 60 --durasi 300
```

Potongan 5 menit (mulai menit ke-1) ditranskripsi oleh semua mesin yang punya API key plus
Whisper lokal, lalu hasilnya terbuka berdampingan di browser. Dengarkan `potongan.wav` dan pilih
kolom yang paling benar.

### 2. Pakai pemenangnya

```bash
# di .env
TRANSCRIPTION_ENGINE=elevenlabs   # atau assemblyai / deepgram / lokal
```

Kamus otomatis ikut dikirim sebagai daftar istilah. Jika mesin cloud gagal (mis. internet
putus), aplikasi otomatis kembali ke Whisper lokal dan mencatatnya di notulen.

> Dengan mesin cloud, audio rapat dikirim ke server penyedia tersebut.

## Pengaturan (`.env`)

| Variabel | Default | Keterangan |
|---|---|---|
| `TRANSCRIPTION_ENGINE` | `lokal` | `lokal` (Whisper), `elevenlabs`, `assemblyai`, atau `deepgram` |
| `ELEVENLABS_API_KEY` / `ASSEMBLYAI_API_KEY` / `DEEPGRAM_API_KEY` | – | API key mesin cloud |
| `SUMMARIZER` | `auto` | `auto`, `claude-code` (langganan Pro/Max), `api` (berbayar), atau `none` (transkrip saja) |
| `CLAUDE_CODE_MODEL` | – | Model untuk mode `claude-code`, mis. `sonnet` atau `opus`. Kosong = default akunmu |
| `ANTHROPIC_API_KEY` | – | Hanya untuk mode `api` |
| `WHISPER_MODEL` | `large-v3-turbo` | `small` lebih cepat tapi kurang akurat; `large-v3` sedikit lebih akurat tapi berat untuk RAM 8 GB |
| `WHISPER_ENGINE` | `auto` | `mlx` (Mac M1/M2/...), `faster-whisper` (Windows/Linux/Mac Intel) |
| `MEETING_LANGUAGE` | `id` | Bahasa utama rapat. `id` tetap menangkap istilah Inggris; pakai `auto` jika rapat dominan Inggris |
| `OUTPUT_DIR` | `~/MeetingNotes` | Folder notulen. Rekaman audio disimpan di subfolder `rekaman/` |
| `CAPTURE_SYSTEM_AUDIO` | `true` | Rekam juga suara dari speaker/headphone |
| `CLAUDE_MODEL` | `claude-opus-5-5` | Model untuk mode `api` |

## Merekam suara peserta meeting online

Kalau kamu pakai **speaker**, mikrofon biasanya sudah menangkap suara peserta lain. Kalau pakai
**headphone**, suara mereka hanya bisa didapat dari audio sistem:

- **Windows & Linux:** otomatis, karena `CAPTURE_SYSTEM_AUDIO=true` merekam audio speaker lalu menggabungkannya dengan mikrofon.
- **macOS:** macOS tidak mengizinkan perekaman audio sistem secara langsung. Pasang
  [BlackHole](https://github.com/ExistentialAudio/BlackHole), buat *Multi-Output Device* di
  Audio MIDI Setup, lalu jadikan BlackHole sebagai input default.

Pastikan semua peserta tahu rapat sedang direkam.

## Pengembangan

```bash
pip install -r requirements-dev.txt
pytest
```

Struktur kode:

| File | Fungsi |
|---|---|
| `meeting_notes/widget.py` | Widget Tkinter (tombol, timer, level suara) |
| `meeting_notes/recorder.py` | Rekam mikrofon + audio sistem, gabungkan jadi satu WAV |
| `meeting_notes/transcriber.py` | Transkripsi lokal (mlx-whisper / faster-whisper), dipotong per 10 menit |
| `meeting_notes/cloud_stt.py` | Transkripsi cloud (ElevenLabs, AssemblyAI, Deepgram) |
| `meeting_notes/compare.py` | Uji tanding mesin transkripsi (`bandingkan`) |
| `meeting_notes/glossary.py` | Kamus otomatis dan penerapan koreksi |
| `meeting_notes/summarizer.py` | Ringkasan terstruktur lewat Claude Code (langganan) atau Claude API |
| `meeting_notes/exporter.py` | Ekspor ke Markdown dan Word |
| `meeting_notes/pipeline.py` | Menyatukan semua langkah |

## Rencana berikutnya

Lihat [docs/ROADMAP.md](docs/ROADMAP.md) dan [CHANGELOG.md](CHANGELOG.md).
