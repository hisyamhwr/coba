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
| 2.1.0 | Perpustakaan rapat, pencarian, dan "Tanya ke rapat" | |
| 2.2.0 | Label pembicara (siapa bicara apa) | Sebagian sudah ada lewat mesin cloud di 1.2.0 |

Referensi UI untuk 2.0.0 ada di [`design-references/`](design-references/). Status lengkap: [CHECKLIST.md](CHECKLIST.md).

## Perangkat target

MacBook Pro 13" M1 (2020), RAM 8 GB, macOS Tahoe 26. Rapat 1–4 jam, bahasa campuran Indonesia–Inggris.
