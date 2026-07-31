# Monitoring Ranking Nasional dengan Supabase

Aplikasi ini memiliki dua mode dalam website yang sama:

- **Viewer** adalah mode default, tanpa login, read-only, dan membaca snapshot nasional aktif dari Supabase.
- **Admin** login dengan email/password Supabase Auth, tetap mengolah Excel di browser, lalu memublikasikan hasil JSON ke Supabase.

File Excel asli tidak pernah dikirim ke Supabase. IndexedDB lama tetap menjadi workspace lokal Admin, sedangkan cache Viewer disimpan di object store terpisah.

## Struktur

```text
Monitoring-Rangking-Nasional-Supabase/
├── index.html
├── .gitignore
├── README.md
├── js/
│   ├── supabase-config.js
│   └── supabase-service.js
└── supabase/
    └── setup.sql
```

## 1. Membuat dan menyiapkan project Supabase

1. Buat project di Supabase.
2. Buka **SQL Editor**, salin seluruh isi `supabase/setup.sql`, lalu jalankan.
3. Buka **Project Settings → API**.
4. Salin **Project URL** dan **Publishable Key**. Jangan memakai Secret Key atau `service_role`.
5. Isi `js/supabase-config.js`:

```js
window.SUPABASE_CONFIG = Object.freeze({
  url: 'https://PROJECT_REF.supabase.co',
  publishableKey: 'PUBLISHABLE_KEY_ANDA'
});
```

Publishable Key memang aman berada di frontend. Pengamanan data dilakukan oleh Row Level Security (RLS). Secret Key, `service_role`, password database, password admin, JWT secret, dan token GitHub tidak boleh masuk repository.

## 2. Membuat Admin

1. Buka **Authentication → Users → Add user**.
2. Buat user dengan email dan password yang kuat.
3. Salin UID user tersebut.
4. Jalankan di SQL Editor:

```sql
insert into public.admin_users (user_id, email)
values ('UID_DARI_AUTH_USERS', 'admin@perusahaan.com')
on conflict (user_id) do update set email = excluded.email;
```

Tidak tersedia sign-up publik dari website. User yang berhasil login tetapi UID-nya tidak ada pada `admin_users` akan ditolak dan dikeluarkan kembali.

## 3. Alur Admin

1. Buka website dan klik **Login Admin**.
2. Masukkan email dan password.
3. Upload Master Cabang jika belum tersedia atau berubah.
4. Upload Excel KPI harian, periksa validasi dan dashboard.
5. Klik **Publikasikan Data Nasional**.
6. Periksa cutoff, revisi, jumlah data, dan ukuran JSON.
7. Klik **Ya, Publikasikan**.

Publikasi tidak pernah berjalan otomatis setelah upload. Snapshot lokal Admin tidak dihapus setelah publikasi.

## 4. Alur Viewer

Viewer cukup membuka URL GitHub Pages. Aplikasi mengambil snapshot aktif sekali saat startup. Tombol **Perbarui Data** dapat dipakai untuk mengambil ulang snapshot tanpa reload penuh. Jika Supabase bermasalah, aplikasi mencoba cache Viewer terakhir.

## 5. Riwayat dan rollback

Admin membuka **Riwayat Publikasi Nasional**, lalu memilih **Aktifkan Kembali**. RPC database menonaktifkan snapshot aktif dan mengaktifkan snapshot pilihan dalam satu transaksi. Viewer melihat hasil rollback setelah refresh atau menekan **Perbarui Data**.

## 6. Deployment GitHub Pages

1. Masukkan seluruh folder ini ke repository GitHub.
2. Pastikan `js/supabase-config.js` sudah berisi Project URL dan Publishable Key.
3. Di Supabase, tambahkan URL GitHub Pages pada **Authentication → URL Configuration → Site URL / Redirect URLs**.
4. Di GitHub buka **Settings → Pages**.
5. Pilih deployment dari branch yang digunakan dan folder root.
6. Buka URL Pages dan lakukan checklist pengujian di bawah.

## Data yang tidak boleh masuk GitHub

- File Excel/CSV perusahaan.
- Secret Key atau `service_role`.
- Password database dan password admin.
- JWT secret.
- Token GitHub.
- File `.env`, `.secret`, atau private key.
- Export `published-data.json`.

## Troubleshooting

- **Konfigurasi belum diisi:** periksa `js/supabase-config.js`; gunakan Project URL dan Publishable Key.
- **CDN gagal dimuat:** periksa koneksi internet dan kebijakan firewall.
- **Login ditolak:** pastikan user ada di Supabase Auth dan UID ada pada `admin_users`.
- **Viewer belum melihat data:** pastikan ada tepat satu baris `published_snapshots` dengan `is_active = true`.
- **Publikasi ditolak:** periksa status Admin, cutoff, revisi duplikat, jumlah record, dan RLS.
- **Cache tidak tersedia:** Viewer harus pernah berhasil memuat snapshot Supabase pada browser tersebut.
- **IndexedDB gagal upgrade:** tutup tab aplikasi lain, buka ulang browser, lalu cek kapasitas penyimpanan.

## Checklist testing

- [ ] Viewer tanpa login tidak melihat menu Admin.
- [ ] Route Admin langsung dialihkan ke Dashboard.
- [ ] Viewer tanpa snapshot mendapat pesan yang benar.
- [ ] Login benar, login salah, non-admin, session refresh, dan logout diuji.
- [ ] Upload Excel, Master Cabang, VACANT, pengaturan KPI, dan riwayat lokal tetap bekerja.
- [ ] Publikasi pertama dan kedua menghasilkan tepat satu snapshot aktif.
- [ ] Publikasi kedua membawa satu `comparisonSnapshot`, tanpa nesting rekursif.
- [ ] Rollback mengaktifkan snapshot pilihan.
- [ ] Anon dan non-admin gagal INSERT/UPDATE/DELETE serta gagal memanggil RPC.
- [ ] Admin berhasil memanggil RPC.
- [ ] Cache Viewer berhasil menjadi fallback.
- [ ] Enam halaman ranking, Detail KPI, search, sorting, filter, Countif, pagination, drill-down, JPG, CSV, floating header, mobile, dan sidebar diuji.
- [ ] Tidak ada token auth pada URL atau UI.
- [ ] Tidak ada Secret Key atau kredensial sensitif di source.
