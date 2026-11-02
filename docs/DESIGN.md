# Sistem desain pulau (aplikasi Mac)

Gaya: **AI-native dark** ala Dynamic Island. Permukaan hitam pekat menyatu dengan notch; setiap status punya
satu warna aksen agar terbaca sekilas; satu elemen utama besar per status (timer, transkrip live, judul rapat).

## Warna

| Token | Hex | Dipakai untuk |
|---|---|---|
| `red` | `#FF453A` | Merekam, tombol stop |
| `orange` | `#FF9F0A` | Momen penting, peringatan, gagal |
| `green` / `mint` | `#30D158` / `#66D4CF` | MoM siap |
| `blue` / `purple` | `#0A84FF` / `#BF5AF2` | Memproses (AI) |
| `pink` | `#FF375F` | Logo & tombol Mulai (gradien `brand`: pink → red → orange) |
| `muted` | putih 55% | Teks sekunder (kontras ±6:1 di atas hitam) |
| `chip` | putih 12% | Latar tombol kapsul/ikon |

## Tipografi

SF Pro Rounded (sistem): angka dan judul terasa ramah, angka timer memakai `monospacedDigit` agar tidak
bergoyang. Skala: 11 (label), 12 (tombol), 15–16 (judul status), 17 (transkrip live), 18 (judul rapat).

## Bentuk

Pulau ringkas: kapsul penuh. Pulau terbuka: sudut bawah 30 pt (continuous). Tombol: kapsul tinggi 28–46 pt,
tombol ikon lingkaran 28 pt. Garis tepi putih 8% pada pulau terbuka, 22–30% pada tombol bergradien.

## Gerak

| Animasi | Kurva | Catatan |
|---|---|---|
| Morph bentuk | spring 0,42 s, bounce 0,22 | Isi disusun pada ukuran akhir, hanya bentuk yang beranimasi |
| Isi masuk / keluar | spring 0,32 s (+0,06 s) / easeIn 0,08 s | |
| Tekan tombol | spring 0,22 s, skala 0,92 + sedikit gelap | Disertai getaran halus trackpad untuk aksi utama |
| Equalizer & cahaya rekam | spring 0,25 s, hanya saat level suara berubah | Tidak ada animasi per frame selama rapat |
| Garis tepi gradien "bernapas" | easeInOut 1,1 s, berulang | Hanya saat memproses; hanya opacity yang beranimasi |
| Centang MoM siap, riak "Penting" | sekali jalan | |

Semua animasi dekoratif mati bila **Reduce motion** aktif di macOS.

Aturan performa: hindari `shadow`, `mask`, `blur`, dan `drawingGroup` pada apa pun yang ikut beranimasi;
animasikan opacity/transform, bukan warna atau ukuran gradien; lapisan dekoratif diberi ukuran akhir pulau.

## Status

Siap (ringkas/terbuka) · Menyiapkan · Merekam (ringkas/terbuka, dengan peringatan bila ada) · Memproses ·
MoM siap · Gagal (dengan Proses ulang). Semua tombol ikon punya tooltip dan label VoiceOver.
