-- DentMatch — 0026 · proxy clinic account สำหรับ job_drafts (โพสต์ในนามแอดมิน ไม่ต้องจับคู่คลินิกจริง)
-- รันหลัง 0001-0025
-- เหตุผล: คลินิกในแชท LINE OpenChat ส่วนใหญ่ไม่มี account จริงในระบบ + ชื่อในแชทยืนยันตัวจริงไม่ได้
--   → แทนที่จะ "จับคู่คลินิกจริง" ก่อนโพสต์ (ของเดิมใน 0025) เปลี่ยนเป็นโพสต์ในนาม proxy clinic เดียว
--   ชื่อคลินิกจริงจากแชทเก็บแยกไว้ที่ job_drafts.clinic_name_text (โชว์ในชื่อ/รายละเอียดงานแทน)
--   matched_clinic_id (0025) ยังเก็บไว้เผื่ออนาคตอยากย้ายไปบัญชีจริง — ไม่บังคับกรอกอีกต่อไป

-- ════════ A) job_drafts.clinic_name_text — ชื่อคลินิกจริงจากแชท (แยกจาก matched_clinic_id) ════════
alter table public.job_drafts
  add column if not exists clinic_name_text text;

-- ════════ B) dm_proxy_clinic_id() — uuid คงที่ของ proxy clinic (ไม่ query ตาราง เร็ว+เรียกจาก client ได้) ════════
create or replace function public.dm_proxy_clinic_id() returns uuid
language sql immutable as $$ select '00000000-0000-0000-0000-0000000d0001'::uuid $$;

-- ════════ C) สร้าง proxy clinic account (idempotent — รันซ้ำได้ไม่พัง) ════════
do $$
declare pid uuid := public.dm_proxy_clinic_id();
begin
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',pid,'authenticated','authenticated','line-import@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (pid,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province,about,verified)
    values (pid,'นำเข้าจาก LINE','กรุงเทพมหานคร','ประกาศงานนำเข้าจากกลุ่ม LINE OpenChat โดยแอดมิน — ชื่อคลินิกจริงระบุไว้ในรายละเอียดงาน',false)
    on conflict (id) do nothing;
end $$;

-- ============================================================
-- TEST (_t26 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t26;
create temp table _t26(test text, result text, pass boolean);
do $$
declare pid uuid := public.dm_proxy_clinic_id();
        cname text;
        crole public.user_role;
begin
  -- T1: proxy clinic id คงที่ทุกครั้งที่เรียก
  insert into _t26 values ('dm_proxy_clinic_id() คืนค่าคงที่', pid::text, pid='00000000-0000-0000-0000-0000000d0001');

  -- T2: มี clinics row จริงของ proxy
  select name into cname from public.clinics where id=pid;
  insert into _t26 values ('proxy clinic มีอยู่ในตาราง clinics', coalesce(cname,'NULL'), cname='นำเข้าจาก LINE');

  -- T3: profiles.role ของ proxy = clinic (ผ่าน routing ปกติถ้า login จริง)
  select role into crole from public.profiles where id=pid;
  insert into _t26 values ('proxy profile role = clinic', crole::text, crole='clinic');

  -- T4: rerun สร้างซ้ำไม่พัง (idempotent) — insert ซ้ำผ่าน on conflict do nothing
  begin
    insert into public.clinics(id,name,province) values (pid,'ชื่อซ้ำ','x') on conflict (id) do nothing;
    insert into _t26 values ('รัน insert ซ้ำไม่ error (idempotent)', 'ok', true);
  exception when others then insert into _t26 values ('รัน insert ซ้ำไม่ error','EXC:'||sqlerrm,false); end;

  -- T5: job_drafts มีคอลัมน์ clinic_name_text แล้ว
  insert into _t26 values ('job_drafts.clinic_name_text มีอยู่',
    (select count(*)::text from information_schema.columns where table_schema='public' and table_name='job_drafts' and column_name='clinic_name_text'),
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='job_drafts' and column_name='clinic_name_text'));
end $$;
select * from _t26;
