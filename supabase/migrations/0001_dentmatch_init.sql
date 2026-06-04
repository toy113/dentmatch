-- DentMatch — initial schema (C1 · Batch 1)
-- รันบน Supabase project ใหม่ผ่าน SQL Editor (ทั้งไฟล์ในครั้งเดียว)
-- ที่มา: DentMatch-Supabase-Schema.md (ฐาน) + DentMatch-Pre-Backend-Decisions.md (decisions 1-5)
-- หลังรันไฟล์นี้ -> รัน supabase/tests/pii_checklist.sql ให้ผ่าน ★ ทุกข้อ ก่อนไป Batch 2

-- ============================================================
-- 1) Extensions
-- ============================================================
create extension if not exists pgcrypto;

-- ============================================================
-- 2) Enums
-- ============================================================
create type user_role        as enum ('worker','clinic','admin');
create type worker_position  as enum ('dentist','assistant','counter');
create type invite_status    as enum ('pending','accepted','declined','expired');
create type worklog_status   as enum ('pending','confirmed','disputed');
create type worklog_outcome  as enum ('came','no_show','cancelled');
create type deletion_status  as enum ('requested','cancelled','completed');
create type rolechg_status   as enum ('pending','approved','rejected');

-- ============================================================
-- 3) Tables
-- ============================================================
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        user_role not null default 'worker',
  created_at  timestamptz not null default now()
);

-- PUBLIC-SAFE (ไม่มี PII) — ทุก authenticated อ่านได้
create table public.worker_profiles (
  id               uuid primary key references public.profiles(id) on delete cascade,
  anon_id          text unique not null,            -- server gen (trigger) — client เลือกเองไม่ได้
  position         worker_position not null default 'assistant',
  position_locked  boolean not null default false,
  skills           text[] not null default '{}',
  province         text not null,
  district         text,                            -- (d4) ระดับเขต
  available        boolean not null default true,
  bio              text,
  trust_score      int not null default 0,          -- = จำนวนงาน confirmed+came (server)
  no_show_count    int not null default 0,          -- (d3) server
  license_verified boolean not null default false,  -- (d5) badge public-safe, server (sync จาก worker_license)
  seeded           boolean not null default false,  -- (d4) analytics, server
  member_since     date not null default current_date,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- PII — เฉพาะเจ้าของ (คลินิกได้ 0 แถวเสมอ)
create table public.worker_private (
  worker_id    uuid primary key references public.worker_profiles(id) on delete cascade,
  first_name   text not null,
  last_name    text not null,
  phone        text not null,
  email        text,
  line_user_id text,
  updated_at   timestamptz not null default now()
);

-- (d5) ใบประกอบ — เฉพาะเจ้าของ ; เอกสารอยู่ใน private storage ; verify โดยแอดมิน
create table public.worker_license (
  worker_id    uuid primary key references public.worker_profiles(id) on delete cascade,
  license_no   text,
  doc_path     text,                                -- path ใน bucket 'licenses' (private)
  verified     boolean not null default false,      -- ★ service_role/admin เท่านั้น
  verified_at  timestamptz,
  verified_by  uuid references public.profiles(id),
  submitted_at timestamptz not null default now()
);

create table public.clinics (
  id                   uuid primary key references public.profiles(id) on delete cascade,
  name                 text not null,               -- ★ admin-locked
  province             text not null,               -- ★ admin-locked
  district             text,                        -- (d4) ★ admin-locked
  line_id              text,
  about                text,
  verified             boolean not null default false,
  plan_tier            text not null default 'free',-- (d2) ★ server/billing
  invite_quota_monthly int,                          -- (d2) null = ไม่จำกัด (launch ฟรี)
  invites_used         int not null default 0,       -- (d2) ★ server
  period_start         date not null default current_date,
  seeded               boolean not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table public.jobs (
  id          uuid primary key default gen_random_uuid(),
  clinic_id   uuid not null references public.clinics(id) on delete cascade,
  title       text not null,
  position    worker_position not null,
  province    text not null,
  district    text,                                 -- (d4)
  wage_text   text,
  work_date   date,
  urgent      boolean not null default false,
  is_boosted  boolean not null default false,       -- (d2) ★ server (paid feature)
  is_open     boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.invites (
  id          uuid primary key default gen_random_uuid(),
  clinic_id   uuid not null references public.clinics(id) on delete cascade,
  worker_id   uuid not null references public.worker_profiles(id) on delete cascade,
  job_id      uuid references public.jobs(id) on delete set null,
  status      invite_status not null default 'pending',
  message     text,
  created_at  timestamptz not null default now(),
  unique (clinic_id, worker_id, job_id)
);

-- (d1/d3) ยืนยัน 2 ฝ่ายด้วย outcome
create table public.work_logs (
  id              uuid primary key default gen_random_uuid(),
  clinic_id       uuid not null references public.clinics(id) on delete cascade,
  worker_id       uuid not null references public.worker_profiles(id) on delete cascade,
  job_id          uuid references public.jobs(id) on delete set null,
  work_date       date not null,
  status          worklog_status not null default 'pending',
  clinic_outcome  worklog_outcome,                  -- null = ยังไม่รายงาน
  worker_outcome  worklog_outcome,
  created_at      timestamptz not null default now()
);

-- (d1) เจตนา handoff ตอนกด Add LINE
create table public.add_line_events (
  id          uuid primary key default gen_random_uuid(),
  worker_id   uuid not null references public.worker_profiles(id) on delete cascade,
  clinic_id   uuid not null references public.clinics(id) on delete cascade,
  job_id      uuid references public.jobs(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table public.deletion_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  status        deletion_status not null default 'requested',
  requested_at  timestamptz not null default now(),
  purge_after   timestamptz not null default (now() + interval '60 days'),
  completed_at  timestamptz
);

create table public.role_change_requests (
  id            uuid primary key default gen_random_uuid(),
  worker_id     uuid not null references public.worker_profiles(id) on delete cascade,
  from_position worker_position not null,
  to_position   worker_position not null,
  status        rolechg_status not null default 'pending',
  created_at    timestamptz not null default now()
);

-- ============================================================
-- 4) Helper
-- ============================================================
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ============================================================
-- 5) Functions + Triggers
-- ============================================================
-- 5.1 updated_at touch (server เซ็ต ไม่ trust client)
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end; $$;
create trigger trg_touch_wp     before update on public.worker_profiles for each row execute function public.touch_updated_at();
create trigger trg_touch_wpriv  before update on public.worker_private  for each row execute function public.touch_updated_at();
create trigger trg_touch_clinic before update on public.clinics         for each row execute function public.touch_updated_at();

-- 5.2 anon_id server-gen (6 หลัก unique) — overwrite ค่าจาก client เสมอ
create or replace function public.gen_anon_id() returns trigger
language plpgsql security definer set search_path = public as $$
declare candidate text;
begin
  loop
    candidate := lpad((floor(random()*1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.worker_profiles where anon_id = candidate);
  end loop;
  new.anon_id := candidate;
  new.position_locked := (new.position = 'dentist');
  return new;
end; $$;
create trigger trg_gen_anon before insert on public.worker_profiles for each row execute function public.gen_anon_id();

-- 5.3 (d5) position lock + license gate
create or replace function public.enforce_position_lock() returns trigger
language plpgsql as $$
begin
  if old.position = 'dentist' and new.position <> 'dentist' then
    raise exception 'ตำแหน่งทันตแพทย์ถูกล็อก เปลี่ยนไม่ได้';
  end if;
  if old.position <> 'dentist' and new.position = 'dentist'
     and not coalesce(new.license_verified, false) then
    raise exception 'การเป็นทันตแพทย์ต้องยืนยันใบประกอบก่อน (license_verified=true)';
  end if;
  new.position_locked := (new.position = 'dentist');
  return new;
end; $$;
create trigger trg_pos_lock before update on public.worker_profiles for each row execute function public.enforce_position_lock();

-- 5.4 (d3) work_logs : BEFORE set status (2 ฝ่ายตรง=confirmed / ไม่ตรง=disputed)
create or replace function public.set_worklog_status() returns trigger
language plpgsql as $$
begin
  if new.clinic_outcome is not null and new.worker_outcome is not null then
    new.status := case when new.clinic_outcome = new.worker_outcome then 'confirmed'::worklog_status
                       else 'disputed'::worklog_status end;
  else
    new.status := 'pending'::worklog_status;
  end if;
  return new;
end; $$;
create trigger trg_wl_status before insert or update on public.work_logs for each row execute function public.set_worklog_status();

-- 5.5 (d3) AFTER recompute cache (นับจากแถวที่ persist แล้ว) — cancelled ไม่เข้า came/no_show
create or replace function public.recompute_trust() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.worker_profiles w set
    trust_score   = (select count(*) from public.work_logs l
                     where l.worker_id = w.id and l.status='confirmed' and l.clinic_outcome='came'),
    no_show_count = (select count(*) from public.work_logs l
                     where l.worker_id = w.id and l.status='confirmed' and l.clinic_outcome='no_show')
  where w.id = coalesce(new.worker_id, old.worker_id);
  return null;
end; $$;
create trigger trg_trust after insert or update or delete on public.work_logs for each row execute function public.recompute_trust();

-- 5.6 (d5) sync badge : worker_license.verified -> worker_profiles.license_verified (ทางเดียว server)
create or replace function public.sync_license_verified() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.worker_profiles set license_verified = new.verified where id = new.worker_id;
  return new;
end; $$;
create trigger trg_sync_license after insert or update of verified on public.worker_license
  for each row execute function public.sync_license_verified();

-- ============================================================
-- 6) RLS enable
-- ============================================================
alter table public.profiles             enable row level security;
alter table public.worker_profiles      enable row level security;
alter table public.worker_private       enable row level security;
alter table public.worker_license       enable row level security;
alter table public.clinics              enable row level security;
alter table public.jobs                 enable row level security;
alter table public.invites              enable row level security;
alter table public.work_logs            enable row level security;
alter table public.add_line_events      enable row level security;
alter table public.deletion_requests    enable row level security;
alter table public.role_change_requests enable row level security;

-- ============================================================
-- 7) Policies
-- ============================================================
create policy p_sel on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy p_ins on public.profiles for insert to authenticated with check (id = auth.uid());

create policy wp_sel on public.worker_profiles for select to authenticated using (true);
create policy wp_ins on public.worker_profiles for insert to authenticated with check (id = auth.uid());
create policy wp_upd on public.worker_profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy wpriv_own on public.worker_private for all to authenticated using (worker_id = auth.uid()) with check (worker_id = auth.uid());

-- ★ worker_license : เจ้าของล้วน (เหมือน worker_private) — คลินิกได้ 0 แถว ; admin ผ่าน service_role
create policy wlic_own on public.worker_license for all to authenticated using (worker_id = auth.uid()) with check (worker_id = auth.uid());

create policy c_sel on public.clinics for select to authenticated using (true);
create policy c_ins on public.clinics for insert to authenticated with check (id = auth.uid());
create policy c_upd on public.clinics for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy j_sel on public.jobs for select to authenticated using (true);
create policy j_cud on public.jobs for all to authenticated using (clinic_id = auth.uid()) with check (clinic_id = auth.uid());

create policy inv_ins on public.invites for insert to authenticated with check (clinic_id = auth.uid());
create policy inv_sel on public.invites for select to authenticated using (clinic_id = auth.uid() or worker_id = auth.uid());
create policy inv_upd on public.invites for update to authenticated using (clinic_id = auth.uid() or worker_id = auth.uid()) with check (clinic_id = auth.uid() or worker_id = auth.uid());

create policy wl_ins on public.work_logs for insert to authenticated with check (clinic_id = auth.uid());
create policy wl_sel on public.work_logs for select to authenticated using (clinic_id = auth.uid() or worker_id = auth.uid());
create policy wl_upd on public.work_logs for update to authenticated using (clinic_id = auth.uid() or worker_id = auth.uid()) with check (clinic_id = auth.uid() or worker_id = auth.uid());

-- (d1) party-scoped + admin (ไม่ public)
create policy ale_ins on public.add_line_events for insert to authenticated with check (worker_id = auth.uid() or clinic_id = auth.uid());
create policy ale_sel on public.add_line_events for select to authenticated using (worker_id = auth.uid() or clinic_id = auth.uid() or public.is_admin());

create policy del_ins on public.deletion_requests for insert to authenticated with check (user_id = auth.uid());
create policy del_sel on public.deletion_requests for select to authenticated using (user_id = auth.uid());
create policy del_upd on public.deletion_requests for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy rc_ins on public.role_change_requests for insert to authenticated with check (worker_id = auth.uid());
create policy rc_sel on public.role_change_requests for select to authenticated using (worker_id = auth.uid());

-- ============================================================
-- 8) Column-level GRANT (กัน client แก้ฟิลด์ server)
-- ============================================================
revoke update on public.worker_profiles from authenticated;
grant  update (position, skills, province, available, bio, district) on public.worker_profiles to authenticated;
-- REVOKE'd: anon_id, position_locked, trust_score, no_show_count, license_verified, seeded, member_since, updated_at

revoke update on public.worker_license from authenticated;
grant  update (license_no, doc_path) on public.worker_license to authenticated;
-- REVOKE'd: verified, verified_at, verified_by (= service_role)

revoke update on public.clinics from authenticated;
grant  update (line_id, about) on public.clinics to authenticated;
-- REVOKE'd: name, province, district, plan_tier, invite_quota_monthly, invites_used, period_start, seeded, updated_at

revoke update on public.jobs from authenticated;
grant  update (title, position, province, district, wage_text, work_date, urgent, is_open) on public.jobs to authenticated;
-- REVOKE'd: is_boosted (= server)

-- ============================================================
-- 9) Admin views (เข้าถึงเฉพาะ service_role)
-- ============================================================
create or replace view public.v_disputed_logs as
  select id, clinic_id, worker_id, job_id, work_date, clinic_outcome, worker_outcome, created_at
  from public.work_logs where status = 'disputed' order by created_at;

create or replace view public.v_trust_abuse as
  select clinic_id, worker_id, count(*) as confirmed_logs, max(created_at) as last_log
  from public.work_logs where status='confirmed'
  group by clinic_id, worker_id having count(*) >= 5 order by confirmed_logs desc;

revoke all on public.v_disputed_logs from authenticated, anon;
revoke all on public.v_trust_abuse  from authenticated, anon;

-- ============================================================
-- 10) Storage : private bucket 'licenses' (d5)
-- ============================================================
insert into storage.buckets (id, name, public) values ('licenses','licenses', false)
  on conflict (id) do nothing;
-- เจ้าของอัป/อ่านที่ path = <worker_id>/* ; admin อ่านผ่าน service_role
create policy lic_owner_rw on storage.objects for all to authenticated
  using      (bucket_id='licenses' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id='licenses' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============================================================
-- เสร็จ schema. ต่อไป: รัน supabase/tests/pii_checklist.sql ให้ผ่าน ★ ทุกข้อ
-- (purge 60 วัน via pg_cron = ทำใน C4 ตาม schema §9)
-- ============================================================
