# Checklist Meeting Notes

Status per 27-10-2026, versi terakhir **2.0.0** (kode selesai, menunggu build & QA di Mac).

Keterangan:
- ✅ **Selesai, terbukti di Mac**: sudah kamu pakai di MacBook dan berjalan.
- ☑️ **Selesai, teruji di server**: kode dan test lulus, tapi belum dibuktikan di Mac.
- ⚠️ **Selesai, belum pernah dijalankan sungguhan**: hanya diuji dengan data tiruan.
- ⬜ **Belum dikerjakan**.

---

## 1. Sudah dikerjakan (versi 1.x)

### Rekam
- ✅ Widget kecil yang selalu tampil di atas: Mulai Catat / Selesai & Rangkum, timer, level suara (1.0.1)
- ✅ Rekam mikrofon laptop (1.0.1)
- ☑️ Tampilkan nama mic yang dipakai, mis. "Mendengarkan via ..." (1.3.0)
- ☑️ Rekaman tetap aman dan bisa diproses ulang bila pemrosesan gagal (1.1.1)
- ⚠️ Rekam audio Zoom/Meet/Teams langsung (digital) di Mac → dibuat di **2.0.0**
  (di Windows/Linux sudah bisa; di Mac saat ini hanya lewat mic/speaker)

### Transkripsi
- ✅ Whisper lokal di Mac M1 (MLX, `large-v3-turbo`), terbukti saat QA 1.1.1
- ✅ Diproses per potongan ±10 menit, bagian sunyi dilewati (1.0.2)
- ☑️ Pengulangan kata saat diam ("mengalokasikan dan ×40") diringkas (1.1.2)
- ☑️ Suara pelan dikuatkan otomatis (1.3.0)
- ⚠️ Mesin cloud: ElevenLabs, AssemblyAI, Deepgram + cadangan otomatis ke Whisper lokal (1.2.0)
- ⚠️ Perintah `bandingkan` untuk uji tanding mesin (1.2.0)
- ⚠️ Label pembicara "Pembicara 1, 2" (hanya dengan mesin cloud) (1.2.0)
- ⚠️ Transkrip live selama rapat → dibuat di **2.0.0**

### Akurasi & kosakata
- ✅ Koreksi salah dengar oleh Claude, mis. girlfriend → frontend (1.1.0), terbukti di Mac
- ✅ Kamus yang belajar sendiri (`~/MeetingNotes/kamus.txt`) (1.1.0)
- ☑️ Koreksi berdasarkan kemiripan bunyi: "store turner" → setor tunai, tanpa menambah kata (1.1.2)
- ☑️ Kamus dasar bawaan ±130 istilah perbankan/produk/IT (1.3.0)

### MoM (notulen)
- ✅ Ringkasan lewat langganan Claude Pro (Claude Code), tanpa API key (1.0.1)
- ✅ MoM per agenda: ringkasan eksekutif, keputusan utama, action items, pembahasan per topik + jam (1.0.2)
- ✅ Transkrip dirapikan jadi paragraf dan dipindah ke lampiran (1.0.2)
- ☑️ Penugasan tidak dobel jadi keputusan; orang yang hanya disebut tidak jadi peserta (1.1.1)
- ✅ Ekspor `.md` dan `.docx`, lampiran daftar koreksi otomatis (1.0.1 / 1.1.0)

### Dokumentasi & kualitas
- ☑️ 34 unit test, README, CHANGELOG, ROADMAP, QA checklist

---

## 2. Belum dibuktikan di Mac (QA tertunda)

| # | Yang perlu dicek | Versi |
|---|---|---|
| 1 | Pengulangan kata saat diam sudah hilang | 1.1.2 |
| 2 | "setor tunai" dan istilah bank lain tertulis benar | 1.1.2 / 1.3.0 |
| 3 | Widget menampilkan nama earphone/mic eksternal | 1.3.0 |
| 4 | Kecepatan proses rapat 5 menit (target < 1-2 menit) | 1.0.2 |
| 5 | Rapat panjang ≥ 1 jam: Mac tidak hang, MoM per agenda | 1.0.2 |
| 6 | (Opsional) Mesin cloud, mis. ElevenLabs | 1.2.0 |

Hasil QA ini sebaiknya dilaporkan sebelum atau sambil mengerjakan 2.0.0, karena "otak" pemrosesannya dipakai ulang di 2.0.0.

---

## 3. 2.0.0 (aplikasi Mac native): kode selesai, belum pernah di-build

Server tidak punya Swift/macOS, jadi semua butir di bawah ⚠️ sampai berhasil di-build dan dicoba di Mac-mu.

### Fondasi
- ⚠️ Paket Swift + `mac/build.sh` yang menghasilkan `MeetingNotes.app` (tanpa perlu membuat proyek Xcode)
- ⚠️ Aplikasi menu bar (tanpa terminal); bisa ditambahkan ke Login Items
- ⚠️ Izin macOS: Mikrofon, Speech Recognition, Screen & System Audio Recording

### Tampilan ala Dynamic Island
- ⚠️ Siap: kapsul kecil; klik → tombol **Mulai Catat** dan **Folder**
- ⚠️ Merekam (ringkas): titik merah, timer, gelombang suara, jumlah momen penting
- ⚠️ Merekam (diperluas): 3 baris transkrip live, chip **Tandai penting**, tombol stop oranye
- ⚠️ Memproses: progress *Mentranskrip → Mengoreksi → Menyusun MoM*
- ⚠️ Selesai: judul rapat, "N keputusan · M action item · K momen penting", **Buka MoM**, **Salin**, **Folder**
- ⚠️ Gagal: pesan + **Buka folder rekaman**

### Audio
- ⚠️ Rekam mic (nama mic tampil)
- ⚠️ Rekam audio Zoom/Meet/Teams langsung (ScreenCaptureKit), juga saat pakai headphone
- ⚠️ Gabung keduanya jadi satu `meeting.wav`

### Selama rapat
- ⚠️ Transkrip live (pengenal suara macOS, bahasa Indonesia)
- ⚠️ **Tandai penting** → bagian "Momen Penting" di MoM (bagian Python ☑️ teruji dengan Claude sungguhan)
- ⚠️ Shortcut global ⌃⌥M

### Setelah rapat
- ☑️ Pemrosesan akhir memakai ulang Python 1.x lewat `proses --json` (teruji di server)
- ⚠️ Notifikasi saat MoM siap; Buka/Salin MoM sekali klik

### QA 2.0.0
- ⬜ Build di Mac dan jalankan checklist QA 2.0.0 di [QA.md](QA.md)

---

## 4. Rencana setelah 2.0.0

- ⬜ **2.1.0** Perpustakaan rapat: riwayat semua rapat, pencarian, dan "Tanya ke rapat"
- ⬜ **2.2.0** Label pembicara (siapa bicara apa) untuk Whisper lokal; sudah ada di mesin cloud sejak 1.2.0

Dibatalkan atas permintaan: integrasi kalender, deteksi rapat otomatis, dan bagikan ke Slack/Notion/email.
