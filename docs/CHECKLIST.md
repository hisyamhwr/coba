# Checklist Meeting Notes

Status per 27-10-2026, versi terakhir **1.3.0**.

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
- ⬜ Rekam audio Zoom/Meet/Teams langsung (digital) di Mac → **2.0.0**
  (di Windows/Linux sudah bisa; di Mac saat ini hanya lewat mic/speaker)

### Transkripsi
- ✅ Whisper lokal di Mac M1 (MLX, `large-v3-turbo`), terbukti saat QA 1.1.1
- ✅ Diproses per potongan ±10 menit, bagian sunyi dilewati (1.0.2)
- ☑️ Pengulangan kata saat diam ("mengalokasikan dan ×40") diringkas (1.1.2)
- ☑️ Suara pelan dikuatkan otomatis (1.3.0)
- ⚠️ Mesin cloud: ElevenLabs, AssemblyAI, Deepgram + cadangan otomatis ke Whisper lokal (1.2.0)
- ⚠️ Perintah `bandingkan` untuk uji tanding mesin (1.2.0)
- ⚠️ Label pembicara "Pembicara 1, 2" (hanya dengan mesin cloud) (1.2.0)
- ⬜ Transkrip live selama rapat → **2.0.0**

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

## 3. Akan dikerjakan: 2.0.0 (aplikasi Mac native)

### Fondasi
- ⬜ Proyek Xcode (Swift/SwiftUI) untuk macOS 26 Tahoe, dijalankan di MacBook Pro M1
- ⬜ Aplikasi menu bar (tanpa terminal), bisa dibuka otomatis saat login
- ⬜ Izin macOS: Mikrofon dan "Screen & System Audio Recording"

### Tampilan ala Dynamic Island (dari `design-references/`)
- ⬜ Siap: kapsul kecil di notch dengan ikon mikrofon
- ⬜ Merekam (ringkas): titik merah, timer besar, gelombang suara
- ⬜ Merekam (diperluas): 2-3 baris transkrip live, chip **Tandai penting**, tombol stop oranye
- ⬜ Memproses: progress bar *Mentranskrip → Mengoreksi → Menyusun MoM*
- ⬜ Selesai: judul rapat, "N keputusan · M action item", chip **Buka MoM** dan **Salin**

### Audio
- ⬜ Rekam mic
- ⬜ Rekam audio Zoom/Meet/Teams langsung (digital), tanpa BlackHole, juga saat pakai headphone
- ⬜ Gabung keduanya jadi satu rekaman

### Selama rapat
- ⬜ Transkrip live (perkiraan cepat, ditampilkan di notch)
- ⬜ Tombol **Tandai penting** → momen ditandai muncul sebagai bagian khusus di MoM
- ⬜ Shortcut keyboard global untuk mulai/berhenti

### Setelah rapat
- ⬜ Pemrosesan akhir yang akurat (Whisper/cloud + koreksi Claude + kamus + MoM), memakai ulang kode 1.x
- ⬜ Notifikasi saat MoM siap; buka atau salin MoM sekali klik

### QA 2.0.0
- ⬜ Checklist QA khusus 2.0.0, diuji bertahap di Mac-mu (aku tulis kode, kamu build & coba di Xcode)

---

## 4. Rencana setelah 2.0.0

- ⬜ **2.1.0** Perpustakaan rapat: riwayat semua rapat, pencarian, dan "Tanya ke rapat"
- ⬜ **2.2.0** Label pembicara (siapa bicara apa) untuk Whisper lokal; sudah ada di mesin cloud sejak 1.2.0

Dibatalkan atas permintaan: integrasi kalender, deteksi rapat otomatis, dan bagikan ke Slack/Notion/email.
