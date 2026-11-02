# Sistem desain pulau (aplikasi Mac)

Gaya: **AI-native dark** ala Dynamic Island, modern dan ceria. Permukaan hitam pekat menyatu dengan notch; setiap status punya
satu warna aksen agar terbaca sekilas; satu elemen utama besar per status (timer, transkrip live, judul rapat).
Satu identitas warna biru-cyan-tosca (dipilih pengguna); ungu sengaja tidak dipakai agar tidak menjadi gradien
biru-ungu yang terkesan generik ("AI slop", lihat skill `swiftui-design-skill`).

## Warna

Tema **neon ocean**: identitas biru elektrik → cyan → tosca, hijau mint untuk selesai, lime sebagai aksen kontras,
dan merah koral hanya untuk rekam/stop/peringatan (merah tetap tanda "sedang merekam" yang paling jelas).

| Token | Hex | Dipakai untuk |
|---|---|---|
| `blue` / `cyan` / `teal` | `#3B82F6` / `#22D3EE` / `#2DD4BF` | Identitas (gradien `brand`), equalizer, cahaya rekam, memproses (`process`), garis tepi "bernapas" |
| `azure` → `deepCyan` | `#2563EB` → `#0891B2` | Tombol aksi utama (`action`: Mulai, Susun ulang); cukup gelap untuk teks putih |
| `mint` | `#34D399` | MoM siap (`done`: teal → mint), jalur suara peserta |
| `lime` | `#C3F53C` | Aksen: momen Penting (bintang, jumlah, riak) |
| `red` / `coral` | `#FF4D6D` / `#FF7A8A` | Titik rekam & tombol stop (`record`) / peringatan & gagal |
| `navy` | `#0B1E3F` | Ikon di atas gradien terang (logo) |
| kata live sementara | cyan → mint | Kata yang masih dikenali |
| `muted` | putih 55% | Teks sekunder (kontras ±6:1 di atas hitam) |
| `chip` | putih 10% | Latar tombol kapsul/ikon |
| `rim` | putih 24% → 4% (atas → bawah) | Tepi "kaca" pada tombol, chip, dan kartu |
| `card` | putih 5,5% | Kartu transkrip live |

## Tipografi

SF Pro (regular) untuk transkrip live dan teks: ringan dan paling mudah dibaca. SF Pro Rounded (medium/semibold)
untuk judul dan angka: ramah dan ceria. Bobot dibatasi regular–semibold agar tidak terasa berat. Angka timer
memakai `monospacedDigit` agar tidak bergoyang. Skala: 11 (label kecil), 12 (tombol), 15 (judul status,
transkrip live), 17 (judul rapat).

Transkrip live selalu menampilkan kata terbaru: teks lama dipotong di depan dengan "…", tidak pernah di kanan.

## Bentuk

Dua gaya, dipilih di menu bar (**Bentuk: Island / Pill**), berpindah dengan animasi morph:

| Gaya | Bentuk | Ringkas | Terbuka |
|---|---|---|---|
| **Island** (bawaan) | Menempel di tepi atas layar/notch. Sudut atas tidak siku: melengkung cekung ke luar ("bahu") sehingga hitamnya mengalir dari tepi layar | bahu 12 pt, sudut bawah 14 pt | bahu 20 pt, sudut bawah 28 pt |
| **Pill** | Kapsul melayang 8 pt di bawah tepi atas (di bawah notch kamera bila ada), garis tepi putih 14% | kapsul penuh | semua sudut 26 pt |

Bentuknya satu `Shape` (`IslandShape`) dengan tiga nilai yang bisa dianimasikan (bahu, sudut atas, sudut
bawah), jadi perubahan ukuran dan gaya terlihat sebagai satu gerakan cair. Tombol: kapsul tinggi 28–46 pt,
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
| Riak tombol Mulai | easeOut 1,8 s, berulang | Hanya selama panel Siap terbuka; skala + opacity |
| Kilau tombol Mulai | easeInOut 0,9 s, sekali | Saat panel Siap muncul |
| Masuk bertahap | spring 0,45 s, jeda 0,02–0,14 s | Setiap isi pulau berganti |

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
