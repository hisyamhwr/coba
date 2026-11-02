# Sistem desain pulau (aplikasi Mac)

Gaya: **AI-native dark** ala Dynamic Island, modern dan ceria. Permukaan hitam pekat menyatu dengan notch; setiap status punya
satu warna aksen agar terbaca sekilas; satu elemen utama besar per status (timer, transkrip live, judul rapat).
Satu identitas warna hangat (pink-oranye-kuning); gradien biru-ungu sengaja tidak dipakai karena terkesan
generik ("AI slop", lihat skill `swiftui-design-skill`).

## Warna

| Token | Hex | Dipakai untuk |
|---|---|---|
| `red` | `#FF453A` | Merekam, tombol stop |
| `orange` | `#FF9F0A` | Momen penting, peringatan, gagal |
| `green` / `mint` | `#30D158` / `#66D4CF` | MoM siap |
| `blue` | `#0A84FF` | Centang Word, jumlah tugas (dipakai hemat) |
| `pink` / `yellow` | `#FF375F` / `#FFD60A` | Logo & tombol Mulai (gradien `brand`: pink → orange → yellow), memproses (gradien `process`: yellow → orange → pink), kata live yang masih dikenali (yellow → orange) |
| `micSource` / `meetingSource` | yellow / mint | Chip jalur suara saat merekam: suaramu (mic) dan peserta online |
| `muted` | putih 55% | Teks sekunder (kontras ±6:1 di atas hitam) |
| `chip` | putih 12% | Latar tombol kapsul/ikon |

## Tipografi

SF Pro (regular) untuk transkrip live dan teks: ringan dan paling mudah dibaca. SF Pro Rounded (medium/semibold)
untuk judul dan angka: ramah dan ceria. Bobot dibatasi regular–semibold agar tidak terasa berat. Angka timer
memakai `monospacedDigit` agar tidak bergoyang. Skala: 11 (label kecil), 12 (tombol), 15 (judul status,
transkrip live), 17 (judul rapat).

Transkrip live selalu menampilkan kata terbaru: teks lama dipotong di depan dengan "…", tidak pernah di kanan.

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
| Centang MoM siap + konfeti, riak "Penting" | sekali jalan | |
| Tombol disorot | spring 0,3 s, skala 1,05 + sedikit terang | |
| Titik "sedang menulis" | easeInOut 0,4 s bergantian | Hanya saat menyusun MoM |

Semua animasi dekoratif mati bila **Reduce motion** aktif di macOS.

## Aliran data (performa)

Data yang berubah cepat dipecah per objek agar tiap perubahan hanya menggambar ulang komponennya sendiri
(panduan `swiftui-expert-skill`: setiap `View` adalah batas invalidasi):

| Objek | Berubah | Diamati oleh |
|---|---|---|
| `AudioLevels` (level campuran, mic, meeting) | ±10x/detik | Equalizer, chip jalur suara, cahaya rekam |
| `RecordingClock` | 1x/detik | Timer |
| `LiveCaption` (teks final + kata sementara) | ±7x/detik saat bicara | Transkrip live |
| `AppState` | jarang | Bentuk & isi pulau |

Sebelumnya level suara dan teks live berada di satu objek, sehingga teks tiga baris ikut ditata ulang setiap
level suara berubah.

Aturan performa: hindari `shadow`, `mask`, `blur`, dan `drawingGroup` pada apa pun yang ikut beranimasi;
animasikan opacity/transform, bukan warna atau ukuran gradien; lapisan dekoratif diberi ukuran akhir pulau.

## Status

Siap (ringkas/terbuka) · Menyiapkan · Merekam (ringkas/terbuka, dengan peringatan bila ada) · Memproses ·
MoM siap · Gagal (dengan Proses ulang). Semua tombol ikon punya tooltip dan label VoiceOver.
