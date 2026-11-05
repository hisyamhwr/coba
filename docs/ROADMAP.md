# Roadmap

Target: aplikasi pencatat rapat ala Fireflies yang berjalan langsung di Mac, tanpa website dan tanpa bot yang ikut join meeting.

## Aturan versi

`MAYOR.FITUR.PERBAIKAN`

- **Angka terakhir:** perubahan atau perbaikan kecil (sampai 99).
- **Angka tengah:** penambahan fitur baru.
- **Angka depan:** peningkatan besar.

## Rencana

| Versi | Isi | Status |
|---|---|---|
| 1.0.1 | MVP: widget Python, transkripsi lokal (Whisper), ringkasan Claude via langganan Pro, ekspor .md dan .docx | ✅ Selesai |
| 1.0.2 | MoM per agenda, transkrip jadi paragraf, transkrip lengkap dipindah ke lampiran, Whisper large-v3-turbo (MLX di Mac) | ✅ Selesai |
| 1.1.0 | Koreksi transkrip oleh Claude dan kamus istilah yang belajar sendiri | ✅ Selesai |
| 1.1.1 | Perbaikan hasil QA server (widget dan kualitas MoM) | ✅ Selesai |
| 1.1.2 | Perbaikan QA Mac: pengulangan kata saat diam, koreksi "setor tunai" | ✅ Selesai |
| 1.2.0 | Mesin transkripsi cloud (ElevenLabs/AssemblyAI/Deepgram), label pembicara, uji tanding `bandingkan` | ✅ Selesai (opsional) |
| 1.3.0 | Kamus dasar ±130 istilah, penguat suara pelan, info mic di widget, tips audio | ✅ Selesai |
| 2.0.0 | Aplikasi Mac native: UI notch ala Dynamic Island, rekam audio Zoom/Meet/Teams langsung, transkrip live, tombol tandai penting, MoM otomatis | ✅ Kode selesai, menunggu build & QA di Mac ([QA.md](QA.md)) |
| 2.1.0 | Istilah developer (FE, BE, DS, flagging, PR, SIT/UAT, ...), rekaman dua jalur (mic & meeting) ditranskripsi terpisah dengan label "Saya (mic)" / "Peserta online" | ✅ Kode selesai, menunggu QA di Mac |
| 2.2.0 | Mode akurat (Whisper large-v3) untuk bicara cepat/belibet; istilah bundling, fetch, UI/UX, kata kerja ber-awalan (di-fetch, di-revert) | ✅ Kode selesai, menunggu QA di Mac |
| 2.3.0 | Optimasi: transkripsi di latar belakang selama rapat, model dipilih otomatis (large-v3 bila Mac kuat), hening dipangkas, MoM via Sonnet (±25 detik untuk rapat 1 jam) | ✅ Kode selesai, menunggu QA di Mac |
| 2.3.1–2.3.4 | Desain ulang pulau, animasi ringan, transkrip live real time | ✅ Selesai |
| 3.0.0 | Siap rapat panjang: petunjuk istilah di setiap jendela Whisper, audio meeting tanpa patahan, transkrip live lebih stabil, MoM dengan Risiko & Blocker dan Susun ulang, pemulihan mic/rekaman, hemat memori | ✅ Kode selesai, menunggu QA rapat ≥ 1 jam |
| 3.1.0 | Tangkapan suara & transkrip live lebih baik (penguat otomatis per jalur, filter dengung, musik dikecualikan, koreksi salah dengar yang dipelajari), pulau lebih ringan dengan chip jalur suara | ✅ Kode selesai, menunggu QA di Mac |
| 3.2.0 | Bentuk pulau ala notch app modern: island dengan bahu melengkung (tanpa sudut siku) atau pill melayang, dipilih di menu bar | ✅ Kode selesai, menunggu QA di Mac |
| 3.3.0 | Desain ulang panel Siap & Merekam: tombol Mulai ringkas, sapaan, chip Word/Live, kartu kaca, efek riak/kilau/masuk bertahap | ✅ Kode selesai, menunggu QA di Mac |
| 3.4.0 | Core Audio tap (eksperimental sejak 3.4.4, bawaan kembali rekam layar), peredam derau mic, transkrip live dua lapis (Apple instan → koreksi Whisper) | ⚠️ Tap gagal di rapat sungguhan; QA ulang |
| 4.0.0 | **Alur rekam → transkrip → MoM**: rekaman video layar 720p30 (seluruh layar / jendela Teams / Zoom), audio mic & peserta terpisah, pantau sisa disk, tanpa transkrip live (ringan untuk Mac 8 GB) | ✅ Kode selesai, menunggu QA di Mac |
| 3.5.0 | **Ringan untuk Mac 8 GB**: model Whisper hemat memori, penjaga tekanan memori (koreksi live melambat, rekaman tidak pernah terganggu), pemakaian RAM/CPU dicatat di log | Rencana |
| 3.6.0 | **Audio meeting lebih bagus**: verifikasi Core Audio tap di Mac pengguna, opsi hanya aplikasi meeting, deteksi suara peserta terlalu pelan/pecah, sinkron mic–meeting untuk rapat panjang | Rencana |
| 3.7.0 | ~~Transkrip live menyerupai ucapan~~ | Dibatalkan: diganti alur 4.0.0 (tanpa transkrip live, transkrip akurat setelah rapat) |
| 3.8.0 | Perpustakaan rapat, pencarian, dan "Tanya ke rapat" | |
| 3.9.0 | Label pembicara per orang untuk peserta online (Whisper lokal) | Mic vs meeting sudah dibedakan di 2.1.0; per orang sudah ada lewat mesin cloud di 1.2.0 |

Referensi UI untuk 2.0.0 ada di [`design-references/`](design-references/). Status lengkap: [CHECKLIST.md](CHECKLIST.md).

## Perangkat target

MacBook Pro 13" M1 (2020), RAM 8 GB, macOS Tahoe 26. Rapat 1–4 jam, bahasa campuran Indonesia–Inggris.

### Prinsip untuk perangkat target (berlaku untuk 3.5.0 dan seterusnya)

- **Anggaran RAM saat rapat**: macOS + Zoom/Teams + browser sudah memakai ±5–6 GB dari 8 GB. Meeting Notes
  (app + worker Whisper) ditargetkan **≤ 1 GB** selama rapat; model besar hanya dimuat saat dibutuhkan.
- **Rekaman tidak pernah dikorbankan**: bila Mac berat, yang dikurangi transkrip live/koreksi Whisper,
  bukan perekaman. Sisa pekerjaan dikejar setelah rapat.
- **Diukur, bukan ditebak**: pemakaian RAM/CPU, keterlambatan koreksi live, dan akurasi live vs final dicatat
  di log, sehingga setiap optimasi terbukti dengan angka.
- **macOS 26**: API terbaru boleh dipakai (Core Audio tap, SpeechAnalyzer) dengan cadangan yang aman.
- **Tanpa regresi**: setiap perbaikan disertai tes otomatis; QA rapat ≥ 1 jam sebelum versi dianggap stabil.
- **Perubahan perekaman tidak pernah langsung jadi bawaan**: cara rekam baru masuk sebagai pilihan
  eksperimental dan baru dijadikan bawaan setelah terbukti merekam di Mac pengguna.
