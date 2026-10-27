# Referensi UI untuk versi 2.0.0

Referensi visual dari pengguna untuk widget aplikasi Mac native (UI notch ala Dynamic Island).

| File | Isi |
|---|---|
| `widget-dark-island.webp` | Kumpulan Live Activity / Dynamic Island bergaya gelap |
| `widget-cards-mixed.webp` | Kumpulan kartu widget terang dan gelap |

## Pola yang diambil

- **Bentuk:** kapsul atau kartu hitam dengan sudut sangat membulat, menempel di notch.
- **Hierarki:** label kecil berwarna di kiri atas, ikon status di kanan atas, angka atau teks utama besar dan tebal di tengah.
- **Angka besar sebagai pusat perhatian:** timer rapat ditampilkan seperti `00:03:32` pada kartu "Ride left".
- **Kartu transkrip live:** kartu "Okay, so you just have to walk straight…" hampir persis kebutuhan kita, dengan teks live yang besar, ikon gelombang suara, tombol chip, dan tombol stop oranye bundar.
- **Tombol chip berbentuk kapsul** untuk aksi cepat.
- **Progress bar tipis** untuk status proses, seperti pada kartu "Harry Potter" dan "Taxi".
- **Kartu "Team Standup · 9:00 Zoom · Join"** cocok sebagai inspirasi tampilan hasil rapat.

## Rancangan awal status widget

| Status | Tampilan |
|---|---|
| Siap | Kapsul kecil di notch dengan ikon mikrofon. Klik untuk mulai. |
| Merekam (ringkas) | Kapsul melebar: titik merah, timer, dan gelombang suara. |
| Merekam (diperluas) | Kartu transkrip live dengan 2–3 baris terakhir, chip **Tandai penting**, dan tombol stop oranye. |
| Memproses | Progress bar tipis dengan langkah: *Mentranskrip → Mengoreksi → Menyusun MoM*. |
| Selesai | Kartu hasil berisi judul rapat, jumlah keputusan dan action item, serta chip **Buka MoM** dan **Salin**. |
