begin;

create extension if not exists pgcrypto;

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

create table if not exists public.published_snapshots (
  id uuid primary key default gen_random_uuid(),
  cutoff_date date not null,
  revision_number integer not null check (revision_number > 0),
  published_at timestamptz not null default now(),
  published_by uuid not null references auth.users(id),
  is_active boolean not null default false,
  payload_json jsonb not null,
  file_name text not null,
  record_count integer not null check (record_count >= 0),
  eligible_count integer not null check (eligible_count >= 0 and eligible_count <= record_count),
  data_schema_version integer not null check (data_schema_version > 0),
  constraint published_snapshots_cutoff_revision_key unique (cutoff_date, revision_number),
  constraint published_snapshots_payload_object_check check (jsonb_typeof(payload_json) = 'object')
);

create unique index if not exists published_snapshots_one_active_idx
  on public.published_snapshots ((is_active))
  where is_active = true;

create index if not exists published_snapshots_published_at_idx
  on public.published_snapshots (published_at desc);

alter table public.admin_users enable row level security;
alter table public.published_snapshots enable row level security;

drop policy if exists "read active national snapshot" on public.published_snapshots;
create policy "read active national snapshot"
  on public.published_snapshots
  for select
  to anon, authenticated
  using (is_active = true);

create or replace function public.is_current_user_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.admin_users au
      where au.user_id = auth.uid()
    );
$$;

revoke all on function public.is_current_user_admin() from public;
grant execute on function public.is_current_user_admin() to authenticated;

drop policy if exists "admins read publication history" on public.published_snapshots;
create policy "admins read publication history"
  on public.published_snapshots
  for select
  to authenticated
  using (public.is_current_user_admin());

create or replace function public.publish_national_snapshot(
  p_cutoff_date date,
  p_revision_number integer,
  p_payload_json jsonb,
  p_file_name text,
  p_record_count integer,
  p_eligible_count integer,
  p_data_schema_version integer
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_snapshot_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Autentikasi diperlukan' using errcode = '42501';
  end if;
  if not public.is_current_user_admin() then
    raise exception 'Akses admin diperlukan' using errcode = '42501';
  end if;
  if p_cutoff_date is null
     or p_revision_number is null or p_revision_number <= 0
     or p_payload_json is null or jsonb_typeof(p_payload_json) is distinct from 'object'
     or coalesce(p_file_name, '') = ''
     or p_record_count is null or p_record_count < 0
     or p_eligible_count is null or p_eligible_count < 0 or p_eligible_count > p_record_count
     or p_data_schema_version is null or p_data_schema_version <= 0 then
    raise exception 'Parameter publikasi tidak valid' using errcode = '22023';
  end if;
  if p_payload_json->>'schemaVersion' is null
     or p_payload_json->'activeSnapshot' is null
     or jsonb_typeof(p_payload_json->'activeSnapshot'->'rawRecords') is distinct from 'array'
     or jsonb_array_length(p_payload_json->'activeSnapshot'->'rawRecords') <> p_record_count
     or p_payload_json->'metadata'->>'cutoffDate' is distinct from p_cutoff_date::text
     or (p_payload_json->'metadata'->>'revisionNumber')::integer is distinct from p_revision_number
     or (p_payload_json->>'schemaVersion')::integer is distinct from p_data_schema_version then
    raise exception 'Struktur payload publikasi tidak valid' using errcode = '22023';
  end if;

  update public.published_snapshots
  set is_active = false
  where is_active = true;

  insert into public.published_snapshots (
    cutoff_date, revision_number, published_by, is_active, payload_json,
    file_name, record_count, eligible_count, data_schema_version
  )
  values (
    p_cutoff_date, p_revision_number, auth.uid(), true, p_payload_json,
    p_file_name, p_record_count, p_eligible_count, p_data_schema_version
  )
  returning id into v_snapshot_id;

  return v_snapshot_id;
end;
$$;

revoke all on function public.publish_national_snapshot(date, integer, jsonb, text, integer, integer, integer) from public;
grant execute on function public.publish_national_snapshot(date, integer, jsonb, text, integer, integer, integer) to authenticated;

create or replace function public.activate_published_snapshot(p_snapshot_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Autentikasi diperlukan' using errcode = '42501';
  end if;
  if not public.is_current_user_admin() then
    raise exception 'Akses admin diperlukan' using errcode = '42501';
  end if;
  if p_snapshot_id is null or not exists (
    select 1 from public.published_snapshots where id = p_snapshot_id
  ) then
    raise exception 'Snapshot tidak ditemukan' using errcode = '22023';
  end if;

  perform 1
  from public.published_snapshots
  where id = p_snapshot_id
  for update;

  update public.published_snapshots
  set is_active = false
  where is_active = true and id <> p_snapshot_id;

  update public.published_snapshots
  set is_active = true
  where id = p_snapshot_id;

  return p_snapshot_id;
end;
$$;

revoke all on function public.activate_published_snapshot(uuid) from public;
grant execute on function public.activate_published_snapshot(uuid) to authenticated;

revoke all privileges on table public.admin_users from anon, authenticated;

revoke all privileges on table public.published_snapshots from anon, authenticated;
grant select (
  id,
  cutoff_date,
  revision_number,
  published_at,
  is_active,
  payload_json,
  file_name,
  record_count,
  eligible_count,
  data_schema_version
) on table public.published_snapshots to anon, authenticated;

commit;

-- Setelah membuat user melalui Supabase Authentication > Users, jadikan admin:
-- insert into public.admin_users (user_id, email)
-- values ('UID_DARI_AUTH_USERS', 'admin@perusahaan.com')
-- on conflict (user_id) do update set email = excluded.email;
