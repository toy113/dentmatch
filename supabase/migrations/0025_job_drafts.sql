-- DentMatch — 0025 · job_drafts (parser agent: นำเข้าประกาศงานจาก LINE OpenChat export)
-- รันหลัง 0001-0024
-- แนวทาง: แอดมิน export .txt จาก LINE OpenChat → parser (LLM) แยกข้อความเป็น draft → เก็บที่นี่รอแอดมินตรวจ/จับคู่คลินิก/ยืนยัน → ค่อยสร้าง jobs จริง
-- ไม่มี auto-publish เด็ดขาด (กันพลาด parser + กันคนแอบโพสต์แทนคลินิกที่ไม่มี account จริง)
-- gate ด้วย is_dm_admin() (เช็ค auth.uid() ตรงกับอีเมลแอดมิน) ไม่ใช้ profiles.role='admin' (เพราะจะชน routing เดิมที่รู้จักแค่ clinic/worker → ดู index.html finishLogin())

-- ════════ A) is_dm_admin() — เช็คอีเมลแอดมินตรงๆ (ไม่ใช่ profiles.role) ════════
create or replace function public.is_dm_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and auth.uid() = (
    select id from auth.users where email = 'sorrawit004@gmail.com'
  );
$$;
revoke all on function public.is_dm_admin() from public;
grant execute on function public.is_dm_admin() to authenticated;

-- ════════ B) ตาราง job_drafts ════════
create table public.job_drafts (
  id                 uuid primary key default gen_random_uuid(),
  raw_message        text not null,                 -- ข้อความดิบจาก LINE export (trace กลับ/debug parser)
  sender_name        text,                           -- ชื่อที่โชว์ใน LINE ตอนส่ง (≠ account จริงในระบบ)
  sent_at            timestamptz,                    -- เวลาที่ส่งในแชท (จาก export ไม่ใช่ created_at ของแถวนี้)
  parsed             jsonb not null default '{}',    -- ผล LLM extract: title, position, wage_text, work_days, work_dates, time_start, time_end, province, district, skills, contact_line_id, confidence
  status             text not null default 'pending' check (status in ('pending','matched','published','rejected')),
  matched_clinic_id  uuid references public.clinics(id) on delete set null,   -- แอดมินจับคู่กับคลินิกจริงในระบบ
  published_job_id   uuid references public.jobs(id) on delete set null,      -- ตั้งหลังกดยืนยัน → สร้าง job จริงแล้ว
  note               text,                           -- แอดมินจดสาเหตุ reject/แก้ไขอะไรบ้าง
  created_by         uuid not null references auth.users(id),
  created_at         timestamptz not null default now()
);

alter table public.job_drafts enable row level security;

-- admin-only ทุก operation (select/insert/update/delete) — ไม่มีใครอื่นแตะได้เลย
create policy jd_all on public.job_drafts for all to authenticated
  using (public.is_dm_admin()) with check (public.is_dm_admin());

-- ============================================================
-- TEST (_t25 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t25;
create temp table _t25(test text, result text, pass boolean);
do $$
declare
  admin_email text := 'sorrawit004@gmail.com';
  admin_uid   uuid;
  other_uid   uuid := '00000000-0000-0000-0000-0000000d2501';
  did         uuid;
  n           int;
  ok          boolean;
  had_admin   boolean := false;
begin
  -- ใช้ admin user จริงถ้ามีอยู่แล้ว ไม่ลบทิ้งตอนจบ (กันกระทบบัญชีจริง) — ถ้ายังไม่มี สร้างชั่วคราวแล้วลบตอนจบ
  select id into admin_uid from auth.users where email = admin_email;
  if admin_uid is null then
    admin_uid := '00000000-0000-0000-0000-0000000d2500';
    insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
      values ('00000000-0000-0000-0000-000000000000',admin_uid,'authenticated','authenticated',admin_email,now(),now(),now(),'{"provider":"email","providers":["email"]}','{}');
  else
    had_admin := true;
  end if;
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',other_uid,'authenticated','authenticated','jd.other@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (other_uid,'clinic') on conflict (id) do nothing;

  -- T1: is_dm_admin() = true สำหรับอีเมลแอดมิน
  perform set_config('request.jwt.claims', json_build_object('sub',admin_uid::text,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select public.is_dm_admin() into ok;
  execute 'reset role';
  insert into _t25 values ('is_dm_admin() = true สำหรับแอดมิน', ok::text, ok is true);

  -- T1b: is_dm_admin() = false สำหรับ user อื่น
  perform set_config('request.jwt.claims', json_build_object('sub',other_uid::text,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select public.is_dm_admin() into ok;
  execute 'reset role';
  insert into _t25 values ('is_dm_admin() = false สำหรับ user อื่น', ok::text, ok is false);

  -- T2: แอดมิน insert draft ได้
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',admin_uid::text,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    insert into public.job_drafts(raw_message,sender_name,parsed,created_by)
      values ('รับสมัครผู้ช่วยทันตแพทย์ ด่วน! ค่าจ้าง 600/วัน','คลินิก ตัวอย่าง','{"position":"assistant"}'::jsonb,admin_uid)
      returning id into did;
    execute 'reset role';
    insert into _t25 values ('แอดมิน insert draft ได้', did::text, did is not null);
  exception when others then execute 'reset role'; insert into _t25 values ('แอดมิน insert draft','EXC:'||sqlerrm,false); end;

  -- T3: แอดมินอ่าน draft ของตัวเองได้
  perform set_config('request.jwt.claims', json_build_object('sub',admin_uid::text,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.job_drafts where id=did;
  execute 'reset role';
  insert into _t25 values ('แอดมินอ่าน draft ได้', n::text, n=1);

  -- T4: user อื่น (ไม่ใช่แอดมิน) อ่าน draft ไม่ได้ (RLS บล็อก → เห็น 0 แถว ไม่ error เพราะ select กรองออกเงียบๆ)
  perform set_config('request.jwt.claims', json_build_object('sub',other_uid::text,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.job_drafts where id=did;
  execute 'reset role';
  insert into _t25 values ('user อื่นอ่าน draft (ต้อง 0)', n::text, n=0);

  -- T5: user อื่น insert draft ไม่ได้ (RLS with check บล็อก)
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',other_uid::text,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    insert into public.job_drafts(raw_message,created_by) values ('แอบโพสต์',other_uid);
    execute 'reset role'; insert into _t25 values ('user อื่น insert (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t25 values ('user อื่น insert (ต้อง fail)','errored ✓',true); end;

  -- เก็บกวาด (ลบเฉพาะที่สร้างเพิ่มในเทสนี้ ไม่แตะ admin user จริงที่มีอยู่แล้ว)
  delete from public.job_drafts where id=did;
  delete from auth.users where id=other_uid;
  if not had_admin then delete from auth.users where id=admin_uid; end if;
end $$;
select * from _t25;
