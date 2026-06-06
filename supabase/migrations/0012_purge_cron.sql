-- DentMatch — 0012 · pg_cron purge 60 วัน (housekeeping ปลอดภัย · ต่อจาก schema §9)
-- รันหลัง 0001-0011
-- โมเดล: ฟังก์ชัน public.purge_expired() ทำ 3 อย่าง (อนุรักษ์นิยม · กัน data loss):
--   1) ลบ add_line_events ที่เก่ากว่า 60 วัน (ephemeral · ใช้แค่ count/noti)
--   2) ลบ invites ที่ "ไม่ใช่ accepted" และเก่ากว่า 60 วัน (pending/declined/expired ที่ตายแล้ว)
--      → เก็บ 'accepted' ไว้เป็นประวัติการจับคู่สำเร็จ
--   3) ลบบัญชีที่ผู้ใช้ขอลบ (deletion_requests) เมื่อพ้น grace ราย ๆ (purge_after < now())
--      → delete auth.users = cascade ลบ public data ทั้งสาย (profiles→worker_*/clinics/jobs/...)
-- ★ ไม่แตะ work_logs โดยตรง = trust ledger (recompute_trust นับจากแถวนี้) · ลบได้ทางเดียวคือ cascade ตอนลบบัญชี
-- ★ ไม่แตะ jobs = บอร์ดซ่อนงานหมดอายุด้วย filter expires_at>now() อยู่แล้ว · ต่ออายุ = ขยาย expires_at
--   (ถ้า cron ปิด is_open จะพัง flow "ต่ออายุ" เพราะ renew ขยายแค่ expires_at ไม่เปิด is_open)
-- pg_cron: เปิด extension ที่ Dashboard > Database > Extensions ก่อน · schedule ด้านล่าง guarded (ไม่ error ถ้ายังไม่เปิด)

-- ════════ A) ฟังก์ชัน purge (security definer · รันด้วยสิทธิ์ owner=postgres → bypass RLS โดยตั้งใจ) ════════
create or replace function public.purge_expired()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cutoff  timestamptz := now() - interval '60 days';
  n_events  int := 0;
  n_invites int := 0;
  n_users   int := 0;
begin
  -- 1) ephemeral handoff-intent events เก่า (>60d)
  delete from public.add_line_events where created_at < v_cutoff;
  get diagnostics n_events = row_count;

  -- 2) invites ที่ตายแล้ว (>60d, ทุกสถานะยกเว้น accepted)
  delete from public.invites where status <> 'accepted' and created_at < v_cutoff;
  get diagnostics n_invites = row_count;

  -- 3) บัญชีที่ขอลบและพ้น grace ราย ๆ — cascade ลบ public data ทั้งหมด
  delete from auth.users u
   where u.id in (
     select dr.user_id from public.deletion_requests dr
      where dr.status = 'requested' and dr.purge_after < now()
   );
  get diagnostics n_users = row_count;

  return format('purge_expired @ %s — add_line_events=%s, invites=%s, accounts=%s',
                now()::text, n_events, n_invites, n_users);
end;
$$;

comment on function public.purge_expired() is
  'DentMatch housekeeping 60 วัน: ลบ add_line_events เก่า · invites ที่ไม่ใช่ accepted เก่า · บัญชีที่ขอลบและพ้น grace. ไม่แตะ work_logs/jobs. รันโดย pg_cron (postgres) หรือ SQL Editor.';

-- ล็อกสิทธิ์: เรียกได้แค่ owner(postgres)/pg_cron — ไม่เปิดให้ client (authenticated/anon)
revoke all on function public.purge_expired() from public;
-- (ถ้าต้องการให้ admin tool เรียกผ่าน service_role RPC ได้: grant execute ... to service_role — ดู ADMIN-RUNBOOK)

-- ════════ B) schedule รายวันผ่าน pg_cron (guarded — รันจริงเมื่อเปิด pg_cron แล้วเท่านั้น) ════════
-- 3-arg cron.schedule(jobname,...) = upsert by name → idempotent
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('dentmatch-purge-60d', '0 3 * * *', 'select public.purge_expired();');
    raise notice '✓ pg_cron: ตั้ง job "dentmatch-purge-60d" รายวัน 03:00 UTC (= 10:00 น. ไทย)';
  else
    raise notice '! pg_cron ยังไม่เปิด → เปิดที่ Dashboard > Database > Extensions (pg_cron) แล้วรันบล็อก cron.schedule ใน ADMIN-RUNBOOK';
  end if;
end $$;

-- ════════ C) SELF-TEST (_t12 : pass ต้อง true ทั้งหมด) ════════
-- ⚠️ บล็อกนี้เรียก public.purge_expired() จริง 1 ครั้ง (global) — pre-launch ปลอดภัย (ไม่มีข้อมูล >60 วัน/คำขอลบจริง)
drop table if exists _t12;
create temp table _t12(test text, result text, pass boolean);
do $$
declare
  cl  uuid := '00000000-0000-0000-0000-0000000c1201';   -- throwaway clinic
  wk  uuid := '00000000-0000-0000-0000-0000000c1202';   -- throwaway worker
  del uuid := '00000000-0000-0000-0000-0000000c1203';   -- throwaway user (จะถูก purge)
  jid uuid := 'cccccccc-1212-1212-1212-121212121212';
  t_old   timestamptz := now() - interval '61 days';
  t_fresh timestamptz := now() - interval '3 days';
  ev_old uuid; ev_new uuid; inv_old uuid; inv_acc uuid;
  n int; res text;
begin
  -- teardown (เผื่อรอบก่อนค้าง) → cascade ลบ profiles/clinics/jobs/events/invites/deletion_requests ของ id ทดสอบ
  delete from auth.users where id in (cl, wk, del);

  -- seed (owner context — bypass RLS)
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',cl, 'authenticated','authenticated','purge.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',wk, 'authenticated','authenticated','purge.worker@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',del,'authenticated','authenticated','purge.delete@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic'),(wk,'worker'),(del,'worker') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิก purge','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (wk,'pg012','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.jobs(id,clinic_id,title,position,province) values (jid,cl,'งาน purge','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- add_line_events : เก่า(>60d) + สด(<60d)
  insert into public.add_line_events(worker_id,clinic_id,job_id,created_at) values (wk,cl,jid,t_old)   returning id into ev_old;
  insert into public.add_line_events(worker_id,clinic_id,job_id,created_at) values (wk,cl,jid,t_fresh) returning id into ev_new;

  -- invites : เก่า declined(ลบ) + เก่า accepted(เก็บ)  · job_id ต่างกัน (jid vs null) เลี่ยง unique
  insert into public.invites(clinic_id,worker_id,job_id,status,created_at) values (cl,wk,jid, 'declined',t_old) returning id into inv_old;
  insert into public.invites(clinic_id,worker_id,job_id,status,created_at) values (cl,wk,null,'accepted',t_old) returning id into inv_acc;

  -- deletion_request : พ้น grace แล้ว (purge_after อดีต)
  insert into public.deletion_requests(user_id,status,purge_after) values (del,'requested', now() - interval '1 day');

  -- ════ รันฟังก์ชันจริง ════
  res := public.purge_expired();

  -- T1: add_line_event เก่า → ถูกลบ
  select count(*) into n from public.add_line_events where id=ev_old;
  insert into _t12 values ('add_line_events เก่า(>60d) ถูกลบ', n::text||' row', n=0);
  -- T2: add_line_event สด → ยังอยู่
  select count(*) into n from public.add_line_events where id=ev_new;
  insert into _t12 values ('add_line_events สด(<60d) ยังอยู่', n::text||' row', n=1);
  -- T3: invite เก่า non-accepted → ถูกลบ
  select count(*) into n from public.invites where id=inv_old;
  insert into _t12 values ('invite เก่า non-accepted(>60d) ถูกลบ', n::text||' row', n=0);
  -- T4: invite accepted เก่า → ยังอยู่ (ประวัติ)
  select count(*) into n from public.invites where id=inv_acc;
  insert into _t12 values ('invite accepted เก่า ยังอยู่ (ประวัติ)', n::text||' row', n=1);
  -- T5: บัญชีพ้น grace → ถูก purge (cascade)
  select count(*) into n from auth.users where id=del;
  insert into _t12 values ('บัญชีพ้น grace ถูกลบ (cascade)', n::text||' row', n=0);
  -- T6: deletion_request cascade หายไปกับ user
  select count(*) into n from public.deletion_requests where user_id=del;
  insert into _t12 values ('deletion_request cascade หายไปกับ user', n::text||' row', n=0);
  -- T7: ฟังก์ชัน return summary text
  insert into _t12 values ('purge_expired() คืน summary text', coalesce(res,'∅'), res is not null and res like 'purge_expired%');

  -- cleanup throwaway (del ถูกลบไปแล้ว)
  delete from auth.users where id in (cl, wk);
end $$;
select * from _t12;
