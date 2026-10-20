# NotchFlow

Utility native macOS yang mengubah area notch menjadi Mini Dock, kontrol media, tampilan aktivitas, dan notifikasi ringkas. Dibangun dengan SwiftUI + AppKit; dikembangkan pada MacBook Air M2.

> Eksperimental, belum setara penuh DynamicLake/Dynamic Island iPhone. Integrasi pesan, panggilan, dan browser bergantung versi aplikasi dan izin macOS. Belum ada distribusi Developer ID yang dinotarisasi.

## Persyaratan

- macOS 13+, Xcode Command Line Tools dengan Swift 5.9+. Tidak perlu membuka aplikasi Xcode.
- Akses tulis ke `/Applications` dan identitas code signing lokal yang valid.
- Python 3 hanya untuk helper aktivitas Terminal.
- Layar notch dipilih otomatis; layar tanpa notch memakai tengah atas. Kompatibilitas semua perangkat/versi belum diuji.

## Instalasi dari source

### 1. Compiler dan source

```sh
xcode-select --install
swift --version
```

Jika Command Line Tools sudah tersedia, tidak perlu instal ulang. Clone repository atau ekstrak ZIP source, lalu buka Terminal di folder `notch-flow`.

### 2. Sertifikat signing lokal — sekali saja

Installer memakai identitas **NotchFlow Local**. Di Keychain Access → Certificate Assistant → Create a Certificate, gunakan nama tersebut, Identity Type **Self Signed Root**, Certificate Type **Code Signing**, lalu simpan di login keychain. Jika diperlukan, atur trust code signing sertifikat agar identitas dianggap valid.

```sh
security find-identity -v -p codesigning
```

Pastikan identitas tersedia beserta private key. Jangan membagikan private key atau memasukkannya ke Git. Pakai identitas yang sama setiap update agar izin Accessibility tidak mudah berubah. Sertifikat lokal bukan notarization Apple dan tidak otomatis dipercaya Mac lain. Jangan menonaktifkan Gatekeeper/SIP.

### 3. Build dan pasang

```sh
chmod +x install.sh
./install.sh
```

Untuk identitas valid lain:

```sh
SIGNING_IDENTITY="Nama identitas signing" ./install.sh
```

Installer membangun release, melakukan signing, menghentikan versi lama, menyimpan bundle sebelumnya ke folder sementara yang dicetak di Terminal, memasang `/Applications/NotchFlow.app`, lalu membukanya. Backup sementara bukan backup permanen dan dapat dibersihkan macOS. Installer menolak fallback ad-hoc signing bila identitas tidak tersedia.

Update: ambil source terbaru dan jalankan `./install.sh` lagi. Pengaturan lokal dipertahankan. Tinjau sendiri permintaan Keychain atau Login Items yang muncul.

## Navigasi sehari-hari

1. Hover ke notch: **Mini Dock** langsung terbuka.
2. Klik ikon untuk membuka/pindah aplikasi.
3. Swipe dua jari kiri/kanan di trackpad **dengan kursor pada judul/header panel** untuk pindah menu.
4. Swipe di deretan ikon Mini Dock menggulir aplikasi, bukan pindah menu.
5. Ikon grid membuka semua alat. Menu bar → Open NotchFlow atau **Control–Option–N** juga membuka panel jika shortcut tersedia.
6. Keluar dari area notch untuk menutup; hover berikutnya kembali ke Mini Dock.

Saat tertutup, aktivitas yang tersedia dapat tampil ringkas di kiri/kanan notch. Notifikasi tertentu dapat membuka panel sendiri. Sudut atas panel melebar melengkung keluar; ukurannya mengikuti informasi layar macOS.

## Mini Dock dan jendela

- **Add app** menambahkan favorit; tetap tersedia ketika aplikasinya ditutup.
- Klik kanan ikon → pin/unpin atau **Choose window…**.
- Titik bawah ikon berarti berjalan; mint berarti aplikasi aktif.
- Drop file ke ikon meminta aplikasi itu membukanya. Dukungan tipe file mengikuti aplikasi tujuan; pengujian lintas aplikasi masih terbatas.
- Memilih jendela memerlukan Accessibility; membuka aplikasi biasa tidak.

Dock bawaan tidak diubah. Perpindahan Spaces mengikuti macOS; opsi Mission Control untuk berpindah ke Space dengan jendela aplikasi dapat membantu. Tidak ada pemilihan Desktop bernomor, tab Terminal, atau chat individual coding agent.

## Media: Apple Music, Spotify, radio, YouTube

Mulai playback di aplikasi asal → buka Music/Media → pilih sumber → **Connect player** → izinkan Automation bila diminta. Previous, play/pause, next, dan seek tersedia sesuai metadata sumber. Radio Apple Music tidak selalu menyediakan judul/durasi. Artwork bergantung sumber.

YouTube mendukung tab watch Safari, Chrome, Brave, dan Edge. Browser mungkin memerlukan **Allow JavaScript from Apple Events** pada menu Develop/Developer. Opsi ini memperluas akses otomasi halaman browser; aktifkan hanya bila kamu membutuhkan integrasi. NotchFlow tidak mengaktifkannya sendiri.

Pencarian YouTube otomatis saat tidak ada media lain diputar dilakukan sekitar 10 detik sekali dan memilih browser/tab cocok pertama, bukan selalu tab terakhir yang dipakai. Previous mengulang video; Next menggunakan tombol Next YouTube. Queue editing dan integrasi universal Now Playing belum tersedia.

## Files

Drag file Finder ke notch untuk membuka rak file. Simpan referensi, drag keluar ke aplikasi lain, gunakan Quick Look/share, atau reveal di Finder. Jika Mini Dock sudah terbuka, drop pada ikon ditujukan untuk membuka file dengan aplikasi tersebut.

Maksimal 40 referensi path disimpan lokal. Menghapus baris tidak menghapus file asli. File tidak disalin ke penyimpanan NotchFlow; file pindah/hilang dapat membuat referensi tidak berlaku. File promises seperti attachment yang belum menjadi file lokal belum didukung.

## Timer, baterai, jam, kalender

- **Timer:** Focus 25 menit, Create 45 menit, Unwind 5 menit; start/pause/reset. Selesai memunculkan pemberitahuan dan suara.
- **Device:** persentase baterai, charging, dan banner perubahan charger.
- **Clock & calendar:** jam lokal dengan detik, tanggal, zona waktu, kalender bulanan, navigasi bulan, Today. **Belum tersambung ke agenda Apple Calendar.**

## Pesan dan panggilan — eksperimental

Grid → bell → **Turn on** jika monitoring mati. Izinkan Accessibility. Banner Telegram/WhatsApp dan preview yang kamu inginkan harus diaktifkan pada macOS/aplikasi asal.

Pesan yang terbaca muncul ringkas sekitar tujuh detik; riwayat maksimal 20 pesan berada di Messages. Clear messages menghapus riwayat; Turn off menghentikan monitoring. Banner yang sudah ada saat monitoring dimulai tidak diputar ulang.

NotchFlow mencoba dismiss banner asli setelah membacanya jika tombol yang tepat tersedia. Banner dapat terlihat sesaat atau gagal ditutup. Jangan mematikan notifikasi sumber untuk menghilangkan duplikasi: banner tersebut juga sumber data NotchFlow.

Status panggilan Telegram, WhatsApp, FaceTime dideteksi best-effort dari UI. **Accept/reject langsung tidak disediakan lagi.** Gunakan kontrol aplikasi asli; jendela panggilan tidak otomatis disembunyikan. Nama pemanggil tertentu memakai OCR lokal dengan izin Screen Recording. FaceTime dan semua versi aplikasi belum terverifikasi.

Pengecekan banner sekitar satu detik, panggilan baru sekitar tiga detik, lebih sering saat panggilan aktif. Tidak ada intersepsi universal, quick reply, pengiriman pesan, atau panggilan keluar. Jangan mengandalkan NotchFlow sebagai satu-satunya penanda panggilan.

## Aktivitas Terminal

Dari folder project, dengan aplikasi terpasang:

```sh
python3 notchflow.py run --title "Build project" -- swift build -c release
python3 notchflow.py update my-task --title "Building" --progress 0.5
python3 notchflow.py update my-task --title "Build complete" --status done
python3 notchflow.py dismiss my-task
```

Wrapper hanya menjalankan command yang diberikan, mempertahankan output/exit status, dan tidak menebak progres. Maksimal 20 aktivitas berada dalam memori dan hilang saat quit.

```text
notchflow://activity?id=example&title=Build&progress=0.5&status=running
```

Percent-encode nilai query. Status `running`/`done`/`failed`, progress `0…1`, `action=dismiss` menghapus berdasarkan ID. Endpoint hanya menerima data tampilan, tidak menjalankan command. Aplikasi lain dapat mengirim label sehingga sumber label tidak terverifikasi. Bukan host DynamicLakeKit dan tidak otomatis melacak chat coding agent.

## Pengaturan dan izin

Grid → gear: pilihan layar, lebar panel, close delay, Launch at login, shortcut pengaturan izin. Reduce Motion mengikuti macOS. Startup dapat membutuhkan persetujuan pada General → Login Items.

| Izin | Kegunaan |
| --- | --- |
| Accessibility | Pemilihan jendela, pembacaan banner/call UI |
| Automation | Membaca/mengontrol pemutar atau browser terkait |
| Screen Recording / Screen & System Audio Recording | OCR nama pemanggil tertentu, opsional |
| Login Items | Startup otomatis, opsional |

Nama menu berbeda antarversi macOS. Hover, Mini Dock dasar, jam, dan kalender lokal tidak membutuhkan Accessibility. Jangan memberikan izin yang tidak diperlukan.

## Troubleshooting

| Masalah | Pemeriksaan |
| --- | --- |
| Signing identity hilang | Periksa `security find-identity -v -p codesigning`, sertifikat valid dan private key di Keychain. |
| Swift/SDK mismatch | Gunakan Command Line Tools sesuai OS. Installer memilih SDK 15.4 bila tersedia untuk menghindari mismatch yang pernah ditemui. |
| Notch tidak muncul | Menu bar → Open NotchFlow; cek Settings → Display dan pastikan satu instance berjalan. |
| Izin aktif tetapi gagal setelah update | Quit; pastikan identitas signing tetap sama. Bila entri izin usang, hapus/tambahkan ulang NotchFlow di Accessibility lalu buka ulang. |
| Musik tidak muncul | Mulai playback, pilih sumber, Connect player, cek Automation. YouTube perlu izin JavaScript dan waktu deteksi. |
| Pesan tidak muncul | Monitoring harus aktif dan banner sumber benar-benar muncul. Preview tersembunyi tidak dijamin terbaca. |
| Call gagal/terlambat terdeteksi | Gunakan aplikasi asli; integrasi bergantung UI, bahasa, dan versi. |
| Swipe tidak bekerja | Kursor harus pada header, bukan ikon atau konten scroll. |
| Auto-start gagal | Periksa toggle Launch at login dan persetujuan Login Items. |

Jika install selesai tetapi launch gagal, pastikan proses lama telah keluar, lalu:

```sh
open /Applications/NotchFlow.app
```

## Privasi dan performa

Preferensi, pin aplikasi/jendela, recent apps, dan path rak file disimpan lokal. Pin jendela memakai judul sebagai identitas. Pesan/activity berada dalam memori; tidak menyalin database pesan. OCR lokal; artwork tertentu diambil dari URL penyedia. Otomasi berkomunikasi dengan pemutar/browser lokal.

Output diagnostik dapat memuat judul jendela/nama kontak: sunting sebelum dibagikan. Jangan commit build, bundle `.app`, sertifikat/private key, atau rahasia.

Audit 17 Oktober 2026: setelah memperbaiki pembacaan metadata semua proses berulang, enam sampel menunjukkan 0,6–0,9% CPU. Bukan jaminan baterai atau beban saat playback. Timer terdaftar dijeda saat layar/sistem tidur atau sesi tidak aktif. Detail: [PROFILING.md](PROFILING.md).

## Pengembangan dan verifikasi

```sh
swift build -c release
.build/release/NotchFlow --self-test
python3 notchflow.py --help
```

Jika SDK mismatch, gunakan konfigurasi SDK/cache pada `install.sh`. Self-test mencakup activity, file references, label kontrol, presentasi Mini Dock, radio, dan batas hover; bukan tes end-to-end semua integrasi. [VERIFICATION.md](VERIFICATION.md) menyimpan catatan verifikasi sebelumnya.

Source utama berada di `Sources/NotchFlow`, konfigurasi build di `Package.swift`, identitas bundle di `Info.plist`, installer di `install.sh`, helper Terminal di `notchflow.py`.

Saat melaporkan bug, sertakan model Mac, versi OS/aplikasi sumber, langkah reproduksi, dan status izin tanpa data pribadi. Lisensi distribusi belum ditetapkan; publikasi source tidak otomatis memberi lisensi open-source.

## Uninstall

Matikan Launch at login, Quit dari menu bar, lalu pindahkan `/Applications/NotchFlow.app` ke Trash. Cabut izin di System Settings bila perlu. Preferensi tidak otomatis dihapus; file asli pada rak tidak terhapus.
