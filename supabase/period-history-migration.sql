-- ============================================================================
-- supabase/period-history-migration.sql
-- PERIOD HISTORY / CLOSING BULANAN — Ranking KPI Nasional
--
-- SASARAN : database PRODUCTION yang SUDAH BERISI DATA pada public.published_snapshots
-- SIFAT   : ADITIF, IDEMPOTENT, NON-DESTRUKTIF
--
--   TIDAK melakukan  : DROP TABLE / DROP COLUMN / TRUNCATE / DELETE
--   TIDAK menghapus  : RPC lama (publish_national_snapshot, activate_published_snapshot,
--                      is_current_user_admin) — semuanya tetap ada dan tetap bekerja
--   TIDAK mengubah   : tipe/arti kolom existing
--                      (id, cutoff_date, revision_number, published_at, published_by,
--                       is_active, payload_json, file_name, record_count,
--                       eligible_count, data_schema_version)
--   TIDAK mematikan  : RLS
--   TIDAK memuat     : secret / service_role key apa pun
--
-- ---------------------------------------------------------------------------
-- ASUMSI (di-verifikasi oleh PRE-FLIGHT pada Bagian 0 — migration GAGAL CEPAT
-- bila asumsi tidak terpenuhi, sehingga tidak ada perubahan setengah jadi):
--   1. Tabel publikasi bernama public.published_snapshots
--   2. Kolom existing minimal: id, cutoff_date, revision_number, published_at,
--      file_name, record_count, eligible_count, is_active, payload_json,
--      data_schema_version
--   3. Ada fungsi public.is_current_user_admin() RETURNS boolean
--   4. RLS sudah aktif pada tabel tersebut
--
-- CATATAN PENTING MENGENAI RPC LAMA (§18 / §24 instruksi):
--   setup.sql existing TIDAK tersedia, sehingga RETURN TYPE persis dari
--   public.publish_national_snapshot(...) TIDAK diketahui. CREATE OR REPLACE
--   FUNCTION di PostgreSQL TIDAK BOLEH mengubah return type -> menebak signature
--   berisiko menggagalkan migration di production.
--
--   Karena itu kompatibilitas RPC lama dijamin dengan cara yang LEBIH AMAN dan
--   independen terhadap signature: TRIGGER pada tabel (Bagian 8).
--   Trigger mengisi period columns untuk SETIAP INSERT — termasuk INSERT dari
--   publish_national_snapshot() lama, dari SQL editor, maupun dari RPC baru.
--   Hasilnya: RPC lama TIDAK PERNAH gagal INSERT karena kolom baru, dan row
--   yang dihasilkannya tetap muncul benar pada period selector.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. PRE-FLIGHT CHECK — gagal cepat, bukan gagal separuh jalan
-- ---------------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  if to_regclass('public.published_snapshots') is null then
    raise exception 'PREFLIGHT: tabel public.published_snapshots tidak ditemukan.';
  end if;

  select string_agg(c.col, ', ')
    into v_missing
  from (values ('id'),('cutoff_date'),('revision_number'),('published_at'),
               ('file_name'),('record_count'),('eligible_count'),
               ('is_active'),('payload_json'),('data_schema_version')) as c(col)
  where not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'published_snapshots'
       and column_name  = c.col
  );

  if v_missing is not null then
    raise exception 'PREFLIGHT: kolom wajib tidak ditemukan pada public.published_snapshots: %', v_missing;
  end if;

  if to_regprocedure('public.is_current_user_admin()') is null then
    raise exception 'PREFLIGHT: fungsi public.is_current_user_admin() tidak ditemukan.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. KOLOM PERIOD (aditif, nullable dulu — lihat §18: bertahap)
--
--    period_month           : tanggal 1 bulan tsb (2026-09-01). Canonical monthly key.
--                             period_key "YYYY-MM" = to_char(period_month,'YYYY-MM').
--                             DATE dipilih (bukan text) agar ordering, index, dan
--                             date_trunc konsisten dengan cutoff_date existing.
--    period_status          : 'MTD' | 'CLOSING'
--    period_revision_number : REVISI PUBLIKASI dalam SATU period (§13)
--    is_period_current      : publikasi RESMI yang dilihat Viewer untuk period itu (§17)
--
--    revision_number lama TETAP dipertahankan apa adanya (per cutoff_date) untuk
--    memenuhi UNIQUE(cutoff_date, revision_number) existing dan audit legacy.
-- ---------------------------------------------------------------------------
alter table public.published_snapshots
  add column if not exists period_month           date,
  add column if not exists period_status          text,
  add column if not exists period_revision_number integer,
  add column if not exists is_period_current      boolean not null default false;

comment on column public.published_snapshots.period_month is
  'Tanggal 1 bulan periode (canonical monthly key). period_key = to_char(period_month, ''YYYY-MM'').';
comment on column public.published_snapshots.period_status is
  'MTD | CLOSING. Sekali CLOSING, periode tidak boleh kembali MTD (dikunci trigger + RPC).';
comment on column public.published_snapshots.period_revision_number is
  'Revisi PUBLIKASI dalam satu period. Berbeda dari revision_number (legacy, per cutoff_date) dan dari Revisi Data di payload.';
comment on column public.published_snapshots.is_period_current is
  'Satu-satunya publikasi resmi yang dibaca Viewer untuk period_month tersebut.';

-- Jaring pengaman: data_schema_version NOT NULL (§23). Default berupa literal tanpa
-- tipe eksplisit sehingga aman baik bila kolomnya integer/smallint maupun text.
do $$
begin
  if not exists (
    select 1 from pg_attribute a
     where a.attrelid = 'public.published_snapshots'::regclass
       and a.attname  = 'data_schema_version'
       and a.atthasdef
  ) then
    alter table public.published_snapshots alter column data_schema_version set default '1';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. BACKFILL period_month (deterministik dari cutoff_date) — §19
-- ---------------------------------------------------------------------------
update public.published_snapshots
   set period_month = date_trunc('month', cutoff_date)::date
 where period_month is null;

-- ---------------------------------------------------------------------------
-- 3. BACKFILL period_status — §19
--    KONSERVATIF: MTD adalah fallback. TIDAK menebak CLOSING dari tanggal akhir
--    bulan. Closing harus dinyatakan eksplisit oleh Admin lewat publish baru.
-- ---------------------------------------------------------------------------
update public.published_snapshots
   set period_status = 'MTD'
 where period_status is null;

-- ---------------------------------------------------------------------------
-- 4. BACKFILL period_revision_number (deterministik, stabil, idempotent)
--    Urutan: published_at, cutoff_date, revision_number, id
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.published_snapshots where period_revision_number is null) then
    with ordered as (
      select id,
             row_number() over (
               partition by date_trunc('month', cutoff_date)::date
               order by published_at asc nulls first,
                        cutoff_date asc,
                        revision_number asc nulls first,
                        id asc
             ) as rn
        from public.published_snapshots
    )
    update public.published_snapshots p
       set period_revision_number = o.rn
      from ordered o
     where p.id = o.id
       and p.period_revision_number is null;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. BACKFILL is_period_current — §19 ("hanya satu is_period_current per period")
--    Aturan deterministik: untuk setiap period_month, publikasi TERBARU
--    (period_revision_number terbesar) menjadi current. Row yang saat ini
--    is_active=true diprioritaskan agar Viewer yang sedang berjalan tidak
--    berpindah dataset saat migration diterapkan.
--    Guard: hanya dijalankan bila belum ada satu pun is_period_current (idempotent).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.published_snapshots where is_period_current) then
    with ranked as (
      select id,
             row_number() over (
               partition by period_month
               order by (is_active is true) desc,
                        period_revision_number desc,
                        published_at desc nulls last,
                        id desc
             ) as rn
        from public.published_snapshots
    )
    update public.published_snapshots p
       set is_period_current = true
      from ranked r
     where p.id = r.id
       and r.rn = 1;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. CONSTRAINT & NOT NULL (baru dijalankan SETELAH backfill — §18 langkah 4)
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.published_snapshots'::regclass
                    and conname  = 'published_snapshots_period_status_chk') then
    alter table public.published_snapshots
      add constraint published_snapshots_period_status_chk
      check (period_status in ('MTD','CLOSING'));
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.published_snapshots'::regclass
                    and conname  = 'published_snapshots_period_month_chk') then
    alter table public.published_snapshots
      add constraint published_snapshots_period_month_chk
      check (period_month = date_trunc('month', period_month)::date
             and period_month = date_trunc('month', cutoff_date)::date);
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.published_snapshots'::regclass
                    and conname  = 'published_snapshots_period_revision_chk') then
    alter table public.published_snapshots
      add constraint published_snapshots_period_revision_chk
      check (period_revision_number >= 1);
  end if;
end $$;

alter table public.published_snapshots alter column period_month           set not null;
alter table public.published_snapshots alter column period_status          set not null;
alter table public.published_snapshots alter column period_revision_number set not null;

-- ---------------------------------------------------------------------------
-- 7. INDEX
--    UNIQUE(cutoff_date, revision_number) LAMA SENGAJA TIDAK DISENTUH.
-- ---------------------------------------------------------------------------

-- Maksimal SATU publikasi resmi per period (§20). Partial unique index -> tahan
-- race condition: dua transaksi concurrent tidak dapat sama-sama commit current.
create unique index if not exists published_snapshots_period_current_uidx
  on public.published_snapshots (period_month)
  where is_period_current;

-- Revisi publikasi unik dalam satu period (§21: anti duplicate revision).
create unique index if not exists published_snapshots_period_revision_uidx
  on public.published_snapshots (period_month, period_revision_number);

-- Index bantu dropdown period selector.
create index if not exists published_snapshots_period_month_idx
  on public.published_snapshots (period_month desc, published_at desc);

-- ---------------------------------------------------------------------------
-- 8. HELPER
-- ---------------------------------------------------------------------------

-- Apakah period tersebut PERNAH memiliki publikasi CLOSING? (Closing irreversible §5)
create or replace function public.period_has_closing_publication(p_period_month date)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.published_snapshots ps
     where ps.period_month = date_trunc('month', p_period_month)::date
       and ps.period_status = 'CLOSING'
  );
$$;

-- ---------------------------------------------------------------------------
-- KUNCI TRANSAKSI — URUTAN WAJIB: (1) period-specific, (2) global-active
-- ---------------------------------------------------------------------------
--   period lock  : 'published_snapshots:period:<YYYY-MM-01>'
--   global lock  : 'published_snapshots:global-active'
--
-- Advisory lock per period saja TIDAK cukup: dua sesi yang mempublikasikan BULAN
-- BERBEDA (mis. September dan Oktober) memegang lock berbeda, sehingga keduanya
-- dapat menghitung ulang is_active secara bersamaan dan menghasilkan dua baris
-- is_active atau baris aktif dari bulan yang lebih lama.
--
-- Semua operasi yang menentukan is_active global karena itu WAJIB melewati
-- recalculate_global_active_publication(), yang mengambil global lock di dalam
-- dirinya. Karena setiap pemanggil sudah memegang period lock lebih dulu,
-- urutannya SELALU period -> global di seluruh code path (publish, legacy
-- publish, legacy activate, activate per period) sehingga tidak ada deadlock.
-- ---------------------------------------------------------------------------
create or replace function public.lock_global_active_publication()
returns void
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  select pg_advisory_xact_lock(hashtextextended('published_snapshots:global-active', 0));
$$;

create or replace function public.lock_publication_period(p_period_month date)
returns void
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  select pg_advisory_xact_lock(
    hashtextextended('published_snapshots:period:' || date_trunc('month', p_period_month)::date::text, 0));
$$;

-- Hitung ulang default global is_active (§17):
--   is_active = publikasi resmi dari PERIOD TERBARU secara global.
-- Backfill bulan lama TIDAK PERNAH merebut is_active dari period yang lebih baru (§14).
--
-- INVARIAN yang dijamin fungsi ini:
--   * maksimal SATU baris is_active = true
--   * baris is_active = true SELALU juga is_period_current = true
--   * baris tersebut berasal dari period_month TERBESAR yang punya publikasi resmi
--
-- Flag transaksi 'rkpi.in_recalc' mencegah trigger aktivasi ikut berjalan atas
-- UPDATE yang dilakukan fungsi ini sendiri (anti rekursi tak berujung).
create or replace function public.recalculate_global_active_publication()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_default_id uuid;
begin
  -- (2) global-active lock — pemanggil sudah memegang period lock lebih dulu.
  perform public.lock_global_active_publication();
  perform set_config('rkpi.in_recalc', '1', true);

  select ps.id
    into v_default_id
    from public.published_snapshots ps
   where ps.is_period_current
   order by ps.period_month desc, ps.period_revision_number desc, ps.id desc
   limit 1;

  update public.published_snapshots ps
     set is_active = false
   where ps.is_active is true
     and (v_default_id is null or ps.id <> v_default_id);

  if v_default_id is not null then
    update public.published_snapshots ps
       set is_active = true
     where ps.id = v_default_id
       and ps.is_active is distinct from true;
  end if;

  perform set_config('rkpi.in_recalc', '', true);
  return v_default_id;
exception when others then
  perform set_config('rkpi.in_recalc', '', true);
  raise;
end;
$$;

revoke all on function public.period_has_closing_publication(date)    from public;
revoke all on function public.recalculate_global_active_publication()  from public;
revoke all on function public.lock_global_active_publication()         from public;
revoke all on function public.lock_publication_period(date)            from public;
grant execute on function public.period_has_closing_publication(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. TRIGGER KOMPATIBILITAS — inilah yang menjaga RPC LAMA tetap hidup (§18/§24)
--
--    BEFORE INSERT:
--      - mengisi period_month / period_status / period_revision_number bila NULL
--      - menegakkan CLOSING lock di level DATABASE untuk SEMUA jalur insert (§5)
--      - menjadikan row baru sebagai publikasi resmi period-nya dan menurunkan
--        publikasi resmi sebelumnya pada period yang sama (§20)
--
--    AFTER INSERT:
--      - menghitung ulang is_active global (§17) sehingga backfill bulan lama
--        lewat jalur mana pun tidak merebut default (§14)
--
--    Efek: publish_national_snapshot() lama TIDAK PERLU diubah signature-nya dan
--    tetap menghasilkan row yang valid untuk fitur period.
-- ---------------------------------------------------------------------------
create or replace function public.published_snapshots_period_defaults()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period date;
begin
  if new.cutoff_date is null then
    raise exception 'INVALID_CUTOFF: cutoff_date wajib diisi.';
  end if;

  v_period := date_trunc('month', coalesce(new.period_month, new.cutoff_date))::date;

  if v_period <> date_trunc('month', new.cutoff_date)::date then
    raise exception 'PERIOD_CUTOFF_MISMATCH: periode % tidak sesuai dengan tanggal data %.',
      to_char(v_period,'YYYY-MM'), to_char(new.cutoff_date,'YYYY-MM-DD');
  end if;

  new.period_month  := v_period;
  new.period_status := upper(trim(coalesce(new.period_status, 'MTD')));
  if new.period_status not in ('MTD','CLOSING') then
    raise exception 'INVALID_PERIOD_STATUS: jenis data harus MTD atau CLOSING.';
  end if;

  -- (1) period lock. Global lock diambil belakangan di dalam recalculate (urutan tetap).
  perform public.lock_publication_period(v_period);

  -- CLOSING LOCK (§5) — berlaku untuk RPC baru, RPC lama, maupun INSERT manual.
  if new.period_status = 'MTD' and public.period_has_closing_publication(v_period) then
    raise exception 'PERIOD_ALREADY_CLOSING: periode % sudah Closing dan tidak dapat kembali ke MTD.',
      to_char(v_period,'YYYY-MM');
  end if;

  if new.period_revision_number is null then
    select coalesce(max(ps.period_revision_number), 0) + 1
      into new.period_revision_number
      from public.published_snapshots ps
     where ps.period_month = v_period;
  end if;

  -- Publikasi baru SELALU menjadi publikasi resmi period-nya (berlaku juga untuk
  -- INSERT dari RPC lama yang tidak mengenal kolom is_period_current).
  new.is_period_current := true;

  update public.published_snapshots ps
     set is_period_current = false
   where ps.period_month = v_period
     and ps.is_period_current;

  -- is_active final ditentukan AFTER INSERT oleh recalculate_global_active_publication().
  new.is_active := false;

  return new;
end;
$$;

create or replace function public.published_snapshots_period_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.recalculate_global_active_publication();
  return null;
end;
$$;

drop trigger if exists published_snapshots_period_defaults_trg on public.published_snapshots;
create trigger published_snapshots_period_defaults_trg
  before insert on public.published_snapshots
  for each row execute function public.published_snapshots_period_defaults();

drop trigger if exists published_snapshots_period_after_insert_trg on public.published_snapshots;
create trigger published_snapshots_period_after_insert_trg
  after insert on public.published_snapshots
  for each row execute function public.published_snapshots_period_after_insert();

-- ---------------------------------------------------------------------------
-- 9b. GUARD JALUR AKTIVASI LAMA (UPDATE is_active) — activate_published_snapshot
-- ---------------------------------------------------------------------------
--     MENGAPA TRIGGER, BUKAN CREATE OR REPLACE RPC LAMA:
--       setup.sql tidak tersedia sehingga RETURN TYPE persis
--       activate_published_snapshot(...) tidak diketahui, dan PostgreSQL menolak
--       CREATE OR REPLACE yang mengubah return type. Menebak = migration gagal di
--       production. Trigger ini mengamankan JALUR UPDATE-nya, sehingga berlaku untuk
--       RPC lama, frontend lama/ter-cache, pemanggil RPC langsung, maupun UPDATE
--       manual di SQL editor. RPC lama TIDAK dihapus dan TIDAK diubah.
--
--     MASALAH YANG DICEGAH:
--       Agustus MTD Rev1 / Agustus Closing Rev2 (current) / September MTD (is_active).
--       Pemanggil lama mengaktifkan Agustus MTD Rev1 -> is_active menunjuk MTD lama,
--       tidak sinkron dengan is_period_current, dan API lama vs API period berbeda.
--
--     ATURAN FINAL saat is_active bergerak false -> true:
--       A. resolve baris target                       (NEW)
--       B. resolve period_key                         (NEW.period_month)
--       C. validasi lifecycle
--       D. MTD pada period yang sudah Closing -> BLOCK (PERIOD_ALREADY_CLOSING)
--       E. target menjadi is_period_current secara atomic dalam period-nya
--       F. is_active dihitung ulang dari period_key terbaru
--       G. is_active hanya boleh menunjuk baris is_period_current = true
--
--     ROLLBACK KE REVISI CLOSING LAMA: DIIZINKAN dan atomic (§3) — target menjadi
--     publikasi resmi period tersebut, lalu is_active global dihitung ulang.
--     Downgrade CLOSING -> MTD tidak pernah terjadi.
--
--     ANTI REKURSI: recalculate_global_active_publication() mengubah is_active juga.
--     Flag transaksi 'rkpi.in_recalc' membuat trigger ini melewatkan UPDATE tersebut,
--     sehingga tidak ada trigger berantai/loop tak berujung.
-- ---------------------------------------------------------------------------
create or replace function public.published_snapshots_activation_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period date;
begin
  -- Lewati UPDATE yang berasal dari recalculate_global_active_publication() sendiri.
  if coalesce(current_setting('rkpi.in_recalc', true), '') = '1' then
    return new;
  end if;

  -- Hanya peduli pada AKTIVASI (false -> true). Menonaktifkan baris tidak dibatasi.
  if not (new.is_active is true and old.is_active is distinct from true) then
    return new;
  end if;

  v_period := date_trunc('month', coalesce(new.period_month, new.cutoff_date))::date;

  -- (1) period lock, lalu (2) global lock lewat recalculate — urutan konsisten.
  perform public.lock_publication_period(v_period);
  perform public.lock_global_active_publication();

  -- D. CLOSING -> MTD tidak pernah boleh terjadi, walau lewat jalur lama.
  if coalesce(new.period_status, 'MTD') = 'MTD'
     and public.period_has_closing_publication(v_period) then
    raise exception 'PERIOD_ALREADY_CLOSING: periode % sudah Closing; publikasi MTD lama tidak dapat diaktifkan kembali.',
      to_char(v_period, 'YYYY-MM');
  end if;

  -- E. Target menjadi publikasi resmi period-nya (rollback Closing lama diizinkan).
  new.is_period_current := true;
  update public.published_snapshots ps
     set is_period_current = false
   where ps.period_month = v_period
     and ps.is_period_current
     and ps.id <> new.id;

  -- F/G. Nilai is_active FINAL ditentukan AFTER UPDATE oleh recalculate, sehingga
  --      backfill bulan lama tidak pernah merebut default dari period yang lebih baru.
  new.is_active := false;
  perform set_config('rkpi.activation_pending', '1', true);
  return new;
end;
$$;

create or replace function public.published_snapshots_activation_after()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(current_setting('rkpi.in_recalc', true), '') = '1' then
    return null;
  end if;
  if coalesce(current_setting('rkpi.activation_pending', true), '') <> '1' then
    return null;
  end if;
  perform set_config('rkpi.activation_pending', '', true);
  perform public.recalculate_global_active_publication();
  return null;
end;
$$;

drop trigger if exists published_snapshots_activation_guard_trg on public.published_snapshots;
create trigger published_snapshots_activation_guard_trg
  before update of is_active, is_period_current on public.published_snapshots
  for each row execute function public.published_snapshots_activation_guard();

drop trigger if exists published_snapshots_activation_after_trg on public.published_snapshots;
create trigger published_snapshots_activation_after_trg
  after update of is_active, is_period_current on public.published_snapshots
  for each row execute function public.published_snapshots_activation_after();

-- ---------------------------------------------------------------------------
-- 10. RPC PUBLISH PERIOD — publish_period_snapshot_v1
--     RPC LAMA TIDAK DIHAPUS. Frontend baru memakai RPC ini.
--
--     Backend adalah SOURCE OF TRUTH untuk publication revision (§21) dan
--     menulis ulang metadata payload agar sama dengan DB (§22).
--
--     CATATAN dynamic SQL: hanya SATU nilai (data_schema_version) ditulis lewat
--     format(%L) karena tipe kolom tersebut tidak diketahui dari luar (integer,
--     smallint, atau text). Literal tanpa tipe akan di-coerce PostgreSQL ke tipe
--     kolom yang sebenarnya. Nilainya bukan input bebas user: sudah divalidasi
--     sebagai token alfanumerik pendek, sehingga tidak ada permukaan SQL injection.
-- ---------------------------------------------------------------------------
create or replace function public.publish_period_snapshot_v1(
  p_payload_json    jsonb,
  p_cutoff_date     date,
  p_period_month    date,
  p_period_status   text,
  p_file_name       text,
  p_record_count    integer,
  p_eligible_count  integer,
  p_data_schema_version text default null
)
returns table (
  out_publication_id          uuid,
  out_period_month            date,
  out_period_status           text,
  out_period_revision_number  integer,
  out_legacy_revision_number  integer,
  out_is_global_active        boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status       text;
  v_period       date;
  v_period_rev   integer;
  v_legacy_rev   integer;
  v_schema       text;
  v_payload      jsonb;
  v_tat_meta     numeric;
  v_tat_snap     numeric;
  v_tat          numeric;
  v_active       jsonb;
  v_metadata     jsonb;
  v_payload_schema text;
  v_payload_count numeric;
  v_payload_eligible numeric;
  v_id           uuid;
  v_default_id   uuid;
begin
  -- 10.1 Auth: wajib login DAN admin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: sesi login diperlukan untuk memublikasikan data.'
      using errcode = '28000';
  end if;
  if not public.is_current_user_admin() then
    raise exception 'ADMIN_REQUIRED: akses admin diperlukan untuk memublikasikan data.'
      using errcode = '42501';
  end if;

  -- 10.2 Validasi input dasar
  if p_payload_json is null or jsonb_typeof(p_payload_json) <> 'object' then
    raise exception 'INVALID_PAYLOAD: payload publikasi tidak valid.';
  end if;
  if p_cutoff_date is null then
    raise exception 'INVALID_CUTOFF: tanggal data wajib diisi.';
  end if;

  v_status := upper(trim(coalesce(p_period_status, '')));
  if v_status not in ('MTD','CLOSING') then
    raise exception 'INVALID_PERIOD_STATUS: jenis data harus MTD atau CLOSING.';
  end if;

  v_period := date_trunc('month', coalesce(p_period_month, p_cutoff_date))::date;
  if v_period <> date_trunc('month', p_cutoff_date)::date then
    raise exception 'PERIOD_CUTOFF_MISMATCH: periode % tidak sesuai dengan tanggal data %.',
      to_char(v_period,'YYYY-MM'), to_char(p_cutoff_date,'YYYY-MM-DD');
  end if;

  -- 10.3 data_schema_version WAJIB terisi (§23)
  v_schema := nullif(trim(coalesce(p_data_schema_version,
                                   p_payload_json ->> 'schemaVersion')), '');
  v_schema := coalesce(v_schema, '1');
  if v_schema !~ '^[A-Za-z0-9._-]{1,32}$' then
    raise exception 'INVALID_SCHEMA_VERSION: data_schema_version tidak valid.';
  end if;

  -- 10.4 Canonical payload integrity. Database adalah FINAL AUTHORITY: payload
  --      dikonfirmasi terhadap parameter RPC SEBELUM metadata dinormalisasi.
  --      Rewrite di bawah tidak boleh menyembunyikan payload stale/tampered.
  v_active := p_payload_json -> 'activeSnapshot';
  if v_active is null or jsonb_typeof(v_active) <> 'object' then
    raise exception 'INVALID_PAYLOAD: activeSnapshot wajib berupa object.';
  end if;
  if coalesce(jsonb_typeof(v_active -> 'rawRecords'), '') <> 'array' then
    raise exception 'INVALID_PAYLOAD: activeSnapshot.rawRecords wajib berupa array.';
  end if;

  v_metadata := p_payload_json -> 'metadata';
  if v_metadata is not null and jsonb_typeof(v_metadata) <> 'object' then
    raise exception 'INVALID_PAYLOAD: metadata wajib berupa object.';
  end if;
  v_metadata := coalesce(v_metadata, '{}'::jsonb);

  -- Field canonical activeSnapshot adalah kontrak payload V5 dan wajib hadir.
  if nullif(trim(v_active ->> 'periodKey'), '') is null
     or trim(v_active ->> 'periodKey') <> to_char(v_period, 'YYYY-MM') then
    raise exception 'PERIOD_PAYLOAD_MISMATCH: activeSnapshot.periodKey (%) tidak sesuai dengan periode database (%).',
      coalesce(v_active ->> 'periodKey', 'kosong'), to_char(v_period, 'YYYY-MM');
  end if;
  if nullif(trim(v_active ->> 'periodStatus'), '') is null
     or upper(trim(v_active ->> 'periodStatus')) <> v_status then
    raise exception 'PERIOD_PAYLOAD_MISMATCH: activeSnapshot.periodStatus (%) tidak sesuai dengan status database (%).',
      coalesce(v_active ->> 'periodStatus', 'kosong'), v_status;
  end if;
  if nullif(trim(v_active ->> 'cutoffDate'), '') is null
     or trim(v_active ->> 'cutoffDate') <> to_char(p_cutoff_date, 'YYYY-MM-DD') then
    raise exception 'PERIOD_PAYLOAD_MISMATCH: activeSnapshot.cutoffDate (%) tidak sesuai dengan cutoff database (%).',
      coalesce(v_active ->> 'cutoffDate', 'kosong'), to_char(p_cutoff_date, 'YYYY-MM-DD');
  end if;

  -- Metadata canonical bersifat legacy-tolerant, tetapi bila tersedia tidak boleh
  -- berkontradiksi dengan parameter RPC maupun activeSnapshot.
  if v_metadata ? 'periodKey'
     and trim(coalesce(v_metadata ->> 'periodKey', '')) <> to_char(v_period, 'YYYY-MM') then
    raise exception 'PERIOD_PAYLOAD_MISMATCH: metadata.periodKey (%) tidak sesuai dengan periode database (%).',
      coalesce(v_metadata ->> 'periodKey', 'kosong'), to_char(v_period, 'YYYY-MM');
  end if;
  if v_metadata ? 'periodStatus'
     and upper(trim(coalesce(v_metadata ->> 'periodStatus', ''))) <> v_status then
    raise exception 'PERIOD_PAYLOAD_MISMATCH: metadata.periodStatus (%) tidak sesuai dengan status database (%).',
      coalesce(v_metadata ->> 'periodStatus', 'kosong'), v_status;
  end if;
  if v_metadata ? 'cutoffDate'
     and trim(coalesce(v_metadata ->> 'cutoffDate', '')) <> to_char(p_cutoff_date, 'YYYY-MM-DD') then
    raise exception 'PERIOD_PAYLOAD_MISMATCH: metadata.cutoffDate (%) tidak sesuai dengan cutoff database (%).',
      coalesce(v_metadata ->> 'cutoffDate', 'kosong'), to_char(p_cutoff_date, 'YYYY-MM-DD');
  end if;

  v_payload_schema := nullif(trim(p_payload_json ->> 'schemaVersion'), '');
  if v_payload_schema is null or v_payload_schema <> v_schema then
    raise exception 'PAYLOAD_SCHEMA_MISMATCH: payload.schemaVersion (%) tidak sesuai dengan data_schema_version database (%).',
      coalesce(p_payload_json ->> 'schemaVersion', 'kosong'), v_schema;
  end if;
  if v_metadata ? 'dataSchemaVersion'
     and trim(coalesce(v_metadata ->> 'dataSchemaVersion', '')) <> v_schema then
    raise exception 'PAYLOAD_SCHEMA_MISMATCH: metadata.dataSchemaVersion (%) tidak sesuai dengan data_schema_version database (%).',
      coalesce(v_metadata ->> 'dataSchemaVersion', 'kosong'), v_schema;
  end if;

  if p_record_count is null or p_record_count < 0 then
    raise exception 'INVALID_RECORD_COUNT: record_count wajib integer dan tidak boleh negatif.';
  end if;
  if jsonb_array_length(v_active -> 'rawRecords') <> p_record_count then
    raise exception 'PAYLOAD_COUNT_MISMATCH: jumlah activeSnapshot.rawRecords (%) tidak sesuai dengan record_count database (%).',
      jsonb_array_length(v_active -> 'rawRecords'), p_record_count;
  end if;
  if v_metadata ? 'recordCount' then
    if jsonb_typeof(v_metadata -> 'recordCount') <> 'number'
       or (v_metadata ->> 'recordCount') !~ '^[0-9]+$' then
      raise exception 'PAYLOAD_COUNT_MISMATCH: metadata.recordCount wajib berupa integer non-negatif.';
    end if;
    v_payload_count := (v_metadata ->> 'recordCount')::numeric;
    if v_payload_count <> p_record_count then
      raise exception 'PAYLOAD_COUNT_MISMATCH: metadata.recordCount (%) tidak sesuai dengan record_count database (%).',
        v_payload_count, p_record_count;
    end if;
  end if;

  if p_eligible_count is null or p_eligible_count < 0 or p_eligible_count > p_record_count then
    raise exception 'INVALID_ELIGIBLE_COUNT: eligible_count wajib integer pada rentang 0 sampai record_count.';
  end if;
  if v_metadata ? 'eligibleCount' then
    if jsonb_typeof(v_metadata -> 'eligibleCount') <> 'number'
       or (v_metadata ->> 'eligibleCount') !~ '^[0-9]+$' then
      raise exception 'PAYLOAD_ELIGIBLE_COUNT_MISMATCH: metadata.eligibleCount wajib berupa integer non-negatif.';
    end if;
    v_payload_eligible := (v_metadata ->> 'eligibleCount')::numeric;
    if v_payload_eligible <> p_eligible_count then
      raise exception 'PAYLOAD_ELIGIBLE_COUNT_MISMATCH: metadata.eligibleCount (%) tidak sesuai dengan eligible_count database (%).',
        v_payload_eligible, p_eligible_count;
    end if;
  end if;

  -- 10.5 (1) period lock (§21). Trigger mengambil lock yang sama — idempotent.
  --      (2) global-active lock diambil belakangan di dalam recalculate, sehingga
  --      urutan period -> global konsisten dengan seluruh code path lain.
  perform public.lock_publication_period(v_period);

  -- 10.6 CLOSING lock (§5) — dicek di sini agar pesan errornya jelas,
  --      dan tetap dijaga ulang oleh trigger untuk jalur insert lain.
  if v_status = 'MTD' and public.period_has_closing_publication(v_period) then
    raise exception 'PERIOD_ALREADY_CLOSING: periode % sudah Closing dan tidak dapat kembali ke MTD.',
      to_char(v_period,'YYYY-MM');
  end if;

  -- 10.7 TAT CLOSING — VALIDASI STRICT (bukan best-effort).
  --
  --   * TAT WAJIB ADA. NULL / field hilang / non-numeric -> BLOCK. Tidak ada fallback
  --     ke 100 dan tidak ada nilai yang ditulis ulang: angka source tidak pernah disentuh.
  --   * Tolerance = 0.01 percentage point, SAMA PERSIS dengan CLOSING_TAT_TOLERANCE
  --     di frontend, sehingga tidak ada celah "lolos backend tapi ditolak frontend".
  --       100.00  -> PASS      99.995 -> PASS
  --       99.98   -> BLOCK     99.50  -> BLOCK     NULL/missing/teks -> BLOCK
  --   * SUMBER KEBENARAN adalah snapshot yang divalidasi frontend
  --     (payload.activeSnapshot.tatMtd), BUKAN angka metadata yang dikirim terpisah.
  --     Bila kedua sumber ada dan berbeda melebihi tolerance -> BLOCK, karena itu
  --     menandakan metadata dimanipulasi terpisah dari dataset.
  if v_status = 'CLOSING' then
    -- to_number gagal (teks/boolean/objek) ditangkap sebagai NULL, lalu diblokir di bawah.
    begin v_tat_meta := (p_payload_json #>> '{metadata,tatMtd}')::numeric;
    exception when others then v_tat_meta := null; end;
    begin v_tat_snap := (p_payload_json #>> '{activeSnapshot,tatMtd}')::numeric;
    exception when others then v_tat_snap := null; end;

    if v_tat_snap is null and v_tat_meta is null then
      raise exception 'CLOSING_TAT_MISSING: TAT tidak tersedia pada payload. Data Closing wajib memuat TAT 100%%.';
    end if;

    -- Konsistensi lintas sumber diperiksa SEBELUM nilai dipakai.
    if v_tat_snap is not null and v_tat_meta is not null
       and abs(v_tat_snap - v_tat_meta) > 0.01 then
      raise exception 'CLOSING_TAT_MISMATCH: TAT snapshot (%) berbeda dari TAT metadata (%). Publikasi Closing dibatalkan.',
        v_tat_snap, v_tat_meta;
    end if;

    -- activeSnapshot adalah source of truth; metadata hanya cadangan bila snapshot legacy.
    v_tat := coalesce(v_tat_snap, v_tat_meta);
    if v_tat is null or abs(v_tat - 100) > 0.01 then
      raise exception 'CLOSING_TAT_INVALID: TAT untuk data Closing wajib 100%% (toleransi 0.01), sumber menunjukkan %.',
        coalesce(v_tat::text, 'kosong');
    end if;
  end if;

  -- 10.8 Nomor revisi dihitung BACKEND (§21)
  select coalesce(max(ps.period_revision_number), 0) + 1
    into v_period_rev
    from public.published_snapshots ps
   where ps.period_month = v_period;

  -- revision_number legacy tetap diisi agar UNIQUE(cutoff_date, revision_number) terpenuhi.
  select coalesce(max(ps.revision_number), 0) + 1
    into v_legacy_rev
    from public.published_snapshots ps
   where ps.cutoff_date = p_cutoff_date;

  -- 10.9 Normalisasi metadata payload agar SAMA dengan DB (§22). Semua field
  --      ini baru ditulis setelah consistency validation di atas PASS.
  v_payload := jsonb_set(p_payload_json, '{schemaVersion}', to_jsonb(v_schema), true);
  v_payload := jsonb_set(v_payload, '{activeSnapshot}',
                 v_active || jsonb_build_object(
                   'periodKey',    to_char(v_period, 'YYYY-MM'),
                   'periodStatus', v_status,
                   'cutoffDate',   to_char(p_cutoff_date, 'YYYY-MM-DD')
                 ), true);
  v_payload := jsonb_set(v_payload, '{metadata}',
                 v_metadata
                 || jsonb_build_object(
                      'revisionNumber',       v_period_rev,
                      'legacyRevisionNumber', v_legacy_rev,
                      'periodKey',            to_char(v_period, 'YYYY-MM'),
                      'periodStatus',         v_status,
                      'cutoffDate',           to_char(p_cutoff_date, 'YYYY-MM-DD'),
                      'dataSchemaVersion',    v_schema,
                      'recordCount',          p_record_count,
                      'eligibleCount',        p_eligible_count
                    ),
                 true);

  -- 10.10 Insert. Trigger BEFORE INSERT akan menurunkan current lama pada period ini
  --      dan AFTER INSERT menghitung ulang is_active global.
  execute format(
    'insert into public.published_snapshots ('
    '  cutoff_date, revision_number, period_month, period_status,'
    '  period_revision_number, is_period_current, is_active,'
    '  file_name, record_count, eligible_count, data_schema_version,'
    '  payload_json, published_by, published_at'
    ') values ($1,$2,$3,$4,$5,true,false,$6,$7,$8,%L,$9,$10,now()) returning id',
    v_schema)
  into v_id
  using p_cutoff_date, v_legacy_rev, v_period, v_status, v_period_rev,
        p_file_name, p_record_count, p_eligible_count,
        v_payload, auth.uid();

  select ps.id into v_default_id
    from public.published_snapshots ps where ps.is_active limit 1;

  out_publication_id         := v_id;
  out_period_month           := v_period;
  out_period_status          := v_status;
  out_period_revision_number := v_period_rev;
  out_legacy_revision_number := v_legacy_rev;
  out_is_global_active       := (v_default_id = v_id);
  return next;
end;
$$;

revoke all on function public.publish_period_snapshot_v1(jsonb, date, date, text, text, integer, integer, text) from public;
grant execute on function public.publish_period_snapshot_v1(jsonb, date, date, text, text, integer, integer, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. RPC ACTIVATE PER PERIOD — activate_period_snapshot_v1
--     Mengembalikan publikasi lama menjadi resmi DALAM SATU period saja.
--     Tidak pernah menghapus history. CLOSING tidak dapat di-downgrade ke MTD.
--     RPC lama activate_published_snapshot TIDAK dihapus.
-- ---------------------------------------------------------------------------
create or replace function public.activate_period_snapshot_v1(p_publication_id uuid)
returns table (
  out_publication_id    uuid,
  out_period_month      date,
  out_period_status     text,
  out_is_global_active  boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row        public.published_snapshots%rowtype;
  v_default_id uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: sesi login diperlukan.' using errcode = '28000';
  end if;
  if not public.is_current_user_admin() then
    raise exception 'ADMIN_REQUIRED: akses admin diperlukan.' using errcode = '42501';
  end if;

  select ps.* into v_row from public.published_snapshots ps where ps.id = p_publication_id;
  if not found then
    raise exception 'PUBLICATION_NOT_FOUND: publikasi tidak ditemukan.';
  end if;

  -- (1) period lock; (2) global-active lock diambil di dalam recalculate di bawah.
  perform public.lock_publication_period(v_row.period_month);

  if v_row.period_status = 'MTD' and public.period_has_closing_publication(v_row.period_month) then
    raise exception 'PERIOD_ALREADY_CLOSING: periode % sudah Closing dan tidak dapat kembali ke MTD.',
      to_char(v_row.period_month,'YYYY-MM');
  end if;

  update public.published_snapshots ps
     set is_period_current = false
   where ps.period_month = v_row.period_month
     and ps.is_period_current
     and ps.id <> v_row.id;

  update public.published_snapshots ps
     set is_period_current = true
   where ps.id = v_row.id
     and ps.is_period_current is distinct from true;

  v_default_id := public.recalculate_global_active_publication();

  out_publication_id   := v_row.id;
  out_period_month     := v_row.period_month;
  out_period_status    := v_row.period_status;
  out_is_global_active := (v_default_id = v_row.id);
  return next;
end;
$$;

revoke all on function public.activate_period_snapshot_v1(uuid) from public;
grant execute on function public.activate_period_snapshot_v1(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 12. RLS — Viewer hanya boleh membaca publikasi RESMI per period (§26/§31)
--     Policy existing TIDAK dihapus; policy ini bersifat tambahan (permissive).
--     RLS TIDAK PERNAH dimatikan.
-- ---------------------------------------------------------------------------
alter table public.published_snapshots enable row level security;

drop policy if exists published_snapshots_period_current_read on public.published_snapshots;
create policy published_snapshots_period_current_read
  on public.published_snapshots
  for select
  to anon, authenticated
  using (is_period_current);

-- ---------------------------------------------------------------------------
-- 13. COLUMN GRANTS — published_by WAJIB PRIVAT (bukan hardening opsional)
-- ---------------------------------------------------------------------------
--     REVOKE per-kolom TIDAK mencabut grant table-level. Karena itu grant
--     table-level dicabut lebih dulu, lalu privilege dibangun ulang secara
--     SELEKTIF hanya pada kolom yang benar-benar dibutuhkan Viewer.
--     Hasilnya deterministik: apa pun bentuk grant sebelumnya, setelah migration
--     anon dan authenticated TIDAK memiliki SELECT pada published_by.
--
--     Kolom yang dibaca frontend (index.html + js/supabase-service.js) hanyalah
--     daftar di bawah; tidak ada fungsi lama yang meminta published_by, sehingga
--     pencabutan ini tidak memutus fungsionalitas existing.
--
--     Admin tetap membaca history lewat kolom yang sama + policy admin existing;
--     published_by tidak pernah dibuat publik hanya demi Admin history.
-- ---------------------------------------------------------------------------
revoke select on public.published_snapshots from anon;
revoke select on public.published_snapshots from authenticated;
revoke select on public.published_snapshots from public;

grant select (
  id, cutoff_date, revision_number, published_at, file_name,
  record_count, eligible_count, data_schema_version, is_active, payload_json,
  period_month, period_status, period_revision_number, is_period_current
) on public.published_snapshots to anon, authenticated;

-- Sabuk pengaman kedua: pastikan tidak ada sisa grant published_by dari state lama.
revoke select (published_by) on public.published_snapshots from anon;
revoke select (published_by) on public.published_snapshots from authenticated;
revoke select (published_by) on public.published_snapshots from public;

-- Verifikasi fail-fast di dalam transaksi yang sama: bila published_by masih
-- terbaca oleh anon/authenticated, migration DIBATALKAN seluruhnya.
do $$
declare v_leak text;
begin
  select string_agg(distinct grantee, ', ')
    into v_leak
  from information_schema.column_privileges
   where table_schema = 'public'
     and table_name   = 'published_snapshots'
     and column_name  = 'published_by'
     and grantee in ('anon', 'authenticated', 'PUBLIC');
  if v_leak is not null then
    raise exception 'SECURITY: published_by masih dapat dibaca oleh %. Migration dibatalkan.', v_leak;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 14. VIEW RINGKAS untuk period selector (§28)
--     TIDAK memuat payload_json (berat) dan TIDAK memuat published_by (privat).
--     security_invoker = true -> RLS tabel tetap berlaku, view tidak mem-bypass.
-- ---------------------------------------------------------------------------
create or replace view public.published_period_index
with (security_invoker = true) as
  select
    ps.id,
    ps.period_month,
    to_char(ps.period_month, 'YYYY-MM') as period_key,
    ps.period_status,
    ps.cutoff_date,
    ps.period_revision_number,
    ps.revision_number,
    ps.published_at,
    ps.file_name,
    ps.record_count,
    ps.eligible_count,
    ps.data_schema_version,
    ps.is_active,
    ps.is_period_current
  from public.published_snapshots ps
  where ps.is_period_current;

grant select on public.published_period_index to anon, authenticated;

commit;

-- ============================================================================
-- 15. CATATAN PRIVILEGE (sudah DIJALANKAN otomatis pada Bagian 13)
-- ----------------------------------------------------------------------------
-- Bagian 13 mencabut SELECT table-level dari anon/authenticated/PUBLIC lalu
-- memberikan kembali HANYA kolom yang dibutuhkan, dan memverifikasinya dalam
-- transaksi yang sama. Tidak ada langkah manual yang tersisa untuk published_by.
--
-- Verifikasi manual setelah deploy (harus 0 baris):
--
--   select grantee, column_name
--     from information_schema.column_privileges
--    where table_schema='public' and table_name='published_snapshots'
--      and column_name='published_by'
--      and grantee in ('anon','authenticated','PUBLIC');
--
-- Bila project Anda memakai role kustom lain di luar anon/authenticated,
-- periksa juga role tersebut — migration ini sengaja tidak menebak nama role
-- yang tidak diketahui.
-- ============================================================================
-- 16. VERIFIKASI SETELAH MIGRATION (read-only, jalankan manual)
-- ----------------------------------------------------------------------------
-- select to_char(period_month,'YYYY-MM') as period_key, period_status,
--        period_revision_number, is_period_current, is_active, cutoff_date
--   from public.published_snapshots
--  order by period_month desc, period_revision_number desc;
--
-- -- harus 0 baris (tidak boleh dua current dalam satu period):
-- select period_month, count(*) from public.published_snapshots
--  where is_period_current group by period_month having count(*) > 1;
--
-- -- harus tepat 1 baris:
-- select count(*) from public.published_snapshots where is_active;
--
-- -- harus 0 baris:
-- select count(*) from public.published_snapshots where data_schema_version is null;
-- ============================================================================
