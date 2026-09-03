# Keuangan Kita — HTML, CSS, JavaScript + Supabase

Website pencatatan keuangan bersama untuk anggota keluarga. Frontend dibuat
dengan HTML, CSS, dan JavaScript murni. Login dan database memakai Supabase.
Website dapat di-deploy sebagai situs statis di Vercel tanpa proses build.

## Fitur

- Login dan pendaftaran dengan email + password.
- Hingga delapan akun aktif dalam satu ruang keluarga.
- Kode undangan 12 karakter untuk menghubungkan anggota keluarga.
- Room master dapat memberi role `Suami`, `Istri`, `Anak`, `None`, atau nama role bebas tanpa mengubah hak akses sistem.
- Income dibagi ke saldo pribadi anggota dan pos tabungan dinamis.
- Room master dapat menambah, mengganti nama, mengatur penyertaan dalam total kekayaan, dan mengarsipkan maksimal 12 pos tabungan aktif.
- Pos tabungan hanya dapat diarsipkan saat saldonya Rp0 dan setelah verifikasi `HAPUS`; riwayat lama tetap mempertahankan identitas posnya.
- Saldo pribadi boleh menjadi minus sebagai catatan utang/defisit setelah konfirmasi. Seluruh pos tabungan tetap tidak boleh minus.
- Transfer saldo antar-pos tanpa mencatat income/outcome.
- Penyesuaian saldo dapat dilakukan dengan mengetik saldo akhir atau nominal penambahan/pengurangan, disertai alasan dan jejak perubahan.
- Pencatatan emas, tanah, perhiasan, kendaraan, properti, dan aset lainnya.
- Dashboard total kekayaan, saldo tersedia, nilai aset, dan arus bulan berjalan.
- Room master dapat mengaktifkan tanggal gajian 1–31 atau menonaktifkannya. Jika nonaktif, rekomendasi harian dihitung sampai tanggal 1 bulan berikutnya.
- Rekomendasi harian tetap menyisihkan tagihan yang belum dibayar dan tidak membatasi nominal Outcome.
- Tagihan bulanan dengan nominal, tanggal berlangganan, serta checklist pembayaran yang otomatis dimulai ulang setiap bulan.
- Form tambah/edit tagihan tampil sebagai dialog tersendiri seperti form Income/Outcome dan tidak menempel di bagian bawah layar.
- Setiap akun hanya dapat mengelola tagihan saldonya sendiri dan tetap dapat melihat tagihan anggota lain.
- Riwayat otomatis membuka bulan berjalan dan dapat difilter berdasarkan jenis, bulan, serta setiap pencatat.
- Room master dapat mengubah atau menghapus transaksi siapa pun; anggota lain hanya dapat mengubah transaksi yang mereka catat sendiri.
- Room master dapat menghapus akses anggota setelah verifikasi `HAPUS` dan saldo anggota menjadi Rp0. Riwayat anggota tetap dipertahankan.
- Room master dapat mengganti nama keluarga dari tombol pensil di bagian identitas room.
- Baris riwayat dapat diketuk untuk melihat detail tanpa masuk ke mode edit; ketuk area di luar kotak untuk menutup detail.
- Item Riwayat terbaru di Beranda dapat diketuk untuk membuka detail transaksi tanpa meninggalkan Beranda.
- Donut chart kategori pada mobile mengikuti filter Riwayat yang aktif, dengan warna teks legenda yang sama seperti segmen chart.
- Edit/hapus transaksi dan aset, serta tab Logs perubahan saldo penting yang dapat difilter per bulan.
- Logs hanya menampilkan Income, Outcome, Transfer, dan Penyesuaian saldo; aktivitas tagihan, checklist pembayaran, aset, dan profil tidak memenuhi daftar tampilan.
- Row Level Security (RLS): pengguna tidak bisa membaca household lain.
- Tampilan responsif untuk HP dan desktop.

## Isi proyek

| File | Fungsi |
|---|---|
| `index.html` | Struktur halaman login, dashboard, transaksi, dan aset |
| `styles.css` | Seluruh tampilan dan versi responsif |
| `app.js` | Login, household, perhitungan, dan operasi database |
| `config.js` | URL dan publishable/anon key Supabase |
| `supabase-schema.sql` | Schema lengkap: tabel, functions, anti-minus, audit, grants, dan RLS |
| `supabase-migration-transfers-logs.sql` | Upgrade instalasi lama untuk transfer, penyesuaian, anti-minus, dan Logs |
| `supabase-migration-monthly-bills.sql` | Upgrade instalasi lama untuk tagihan bulanan, checklist, audit, dan izin pemilik |
| `supabase-migration-family-members.sql` | Upgrade anggota dinamis, role keluarga, saldo pribadi, izin room master, dan saldo defisit |
| `supabase-migration-important-logs.sql` | Membatasi audit baru ke perubahan saldo penting dan menghentikan log tagihan/aset |
| `supabase-migration-dynamic-savings-settings.sql` | Menambah pos tabungan dinamis, arsip aman, nama keluarga, dan pengaturan gajian |
| `vercel.json` | Security headers untuk Vercel |
| `favicon.svg` | Ikon aplikasi |

## 1. Membuat database Supabase

1. Buka https://supabase.com dan buat project baru.
2. Tunggu sampai project selesai dibuat.
3. Buka **SQL Editor** → **New query**.
4. Salin seluruh isi `supabase-schema.sql`.
5. Tempel ke SQL Editor, lalu klik **Run**.
6. Pastikan tabel berikut muncul di **Table Editor**:
   - `households`
   - `household_members`
   - `household_member_profiles`
   - `transactions`
   - `assets`
   - `balance_transfers`
   - `balance_adjustments`
   - `audit_logs`
   - `monthly_bills`
   - `monthly_bill_payments`
   - `savings_accounts`

SQL tersebut juga mengaktifkan RLS. Jangan menonaktifkan RLS karena itulah
lapisan yang membatasi data setiap keluarga.

### Jika database sudah pernah dipasang

Untuk database dari versi lama, jalankan isi
`supabase-migration-transfers-logs.sql` melalui SQL Editor sebelum mengunggah
frontend versi ini. Jika migration tersebut sudah pernah berhasil dijalankan,
tidak perlu menjalankannya lagi.

Setelah itu jalankan `supabase-migration-monthly-bills.sql`. Migration ini
wajib untuk versi yang memiliki menu tagihan bulanan. Checklist pembayaran
hanya menjadi penanda; pembayaran tetap dicatat manual melalui Outcome.
File migration versi terbaru aman dijalankan ulang untuk memperbaiki instalasi
tagihan yang sempat berhenti di tengah atau menghasilkan respons HTTP 400.

Terakhir, jalankan `supabase-migration-family-members.sql`. Migration ini wajib
untuk versi 19. Data lama tetap dipertahankan: pembuat room lama diberi label
`Suami`, anggota lama diberi label `Istri`, sedangkan anggota baru memakai
role `None` sampai diubah oleh room master. Jalankan hanya tab SQL migration
tersebut, bukan semua tab SQL Editor sekaligus.

Untuk versi 20, lanjutkan dengan `supabase-migration-important-logs.sql`.
Migration ini tidak menghapus log lama dari database. Frontend menyembunyikan
log yang tidak berkaitan dengan perubahan saldo, sementara aktivitas tagihan
dan aset baru tidak lagi menambah audit log.

Untuk versi 21, jalankan `supabase-migration-dynamic-savings-settings.sql`
setelah migration versi 20. Migration ini membuat tiga pos awal dari data lama:
`Tabungan bersama` dan `Tabungan istri` tetap masuk total kekayaan, sedangkan
`Pendidikan` tetap ditampilkan tetapi tidak dihitung. Saldo dan riwayat lama
tidak dipindah atau dihapus. Jalankan hanya isi tab migration ini sekali; file
aman dijalankan ulang jika proses sebelumnya terhenti.

## 2. Menyambungkan frontend ke Supabase

1. Di Supabase, buka **Project Settings** → **API**.
2. Salin **Project URL**.
3. Salin **Publishable key**. Jika project masih menggunakan key lama, salin
   **anon public key**.
4. Buka `config.js`, kemudian ganti:

```js
export const SUPABASE_URL = "https://PROJECT-ID.supabase.co";
export const SUPABASE_PUBLISHABLE_KEY = "PUBLISHABLE-ATAU-ANON-KEY";
```

Publishable key/anon key memang dirancang untuk frontend dan boleh terlihat di
browser ketika RLS aktif. Jangan pernah memasukkan **secret key** atau
**service_role key** ke dalam `config.js`.

## 3. Mengatur login dan URL

Di Supabase, buka **Authentication** → **URL Configuration**.

Saat mencoba secara lokal, tambahkan:

```text
http://localhost:5500/**
```

Setelah memperoleh alamat Vercel, atur:

- **Site URL**: `https://nama-project.vercel.app`
- **Redirect URLs**: `https://nama-project.vercel.app/**`

Secara default Supabase dapat meminta konfirmasi email setelah pendaftaran.
Untuk penggunaan pribadi, sebaiknya fitur konfirmasi email tetap diaktifkan.

## 4. Mencoba secara lokal

Jangan membuka `index.html` langsung dengan klik dua kali karena file ini
menggunakan JavaScript module. Jalankan melalui local server.

Pilihan termudah:

1. Buka folder proyek di VS Code.
2. Pasang extension **Live Server**.
3. Klik kanan `index.html` → **Open with Live Server**.

Atau dengan Python:

```bash
python -m http.server 5500
```

Kemudian buka http://localhost:5500.

## 5. Deploy ke Vercel

### Pilihan A — melalui GitHub

1. Buat repository GitHub baru.
2. Upload seluruh file proyek ke bagian root repository.
3. Buka https://vercel.com/new.
4. Import repository tersebut.
5. Pilih **Framework Preset: Other**.
6. Build Command tidak perlu diisi.
7. Output Directory tidak perlu diisi.
8. Klik **Deploy**.
9. Masukkan URL hasil deploy ke Supabase Authentication URL Configuration.

### Pilihan B — menggunakan Vercel CLI

Dari folder proyek:

```bash
npx vercel
```

Ikuti pertanyaan di terminal. Pilih project baru dan biarkan pengaturan build
tetap kosong karena ini website statis.

## 6. Cara menghubungkan anggota keluarga

1. Pengguna pertama mendaftar dan login.
2. Pilih **Buat ruang baru**.
3. Salin kode undangan 12 karakter yang muncul di sidebar.
4. Anggota lain mendaftar menggunakan email masing-masing.
5. Anggota memilih **Gabung keluarga** dan memasukkan kode tersebut.
6. Room master membuka **Kelola anggota** untuk menetapkan role keluarga.

Jangan membagikan kode undangan kepada orang di luar keluarga. Satu room
mendukung maksimal delapan anggota aktif dan setiap akun hanya dapat bergabung
dalam satu household pada satu waktu.

## Keamanan

- Data keuangan tidak disimpan di file HTML atau localStorage.
- Session login dikelola oleh Supabase Auth.
- Semua query database membawa token pengguna.
- RLS memeriksa keanggotaan household untuk setiap akses.
- Secret/service role key tidak digunakan di browser.
- Security headers disediakan melalui `vercel.json`.

Untuk penggunaan pribadi, lakukan ekspor atau backup data secara berkala.
Paket gratis penyedia layanan dapat berubah dan tidak ada layanan cloud yang
dapat menjamin penyimpanan gratis selamanya.
