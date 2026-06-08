-- DentMatch — 0022 · work_logs กันบันทึกซ้ำต่อ (worker + งาน + วัน)
-- รันหลัง 0001-0021
-- บริบท: งาน 1 โพสต์มีหลายวัน + หลาย worker → บันทึกผล "ระดับรายวัน"
--   work_logs 1 แถว = (worker, งาน, วัน) 1 ผล → worker ทำ 3 วัน = 3 แถว (ตั้งใจ)
--   เดิมไม่มี unique → กดบันทึกซ้ำวันเดิมได้ → trust_score พอง → เพิ่ม unique index กัน
-- job_id nullable: null = นับเป็น distinct (legacy/manual) ไม่กระทบ flow นี้

create unique index if not exists work_logs_worker_job_date_uniq
  on public.work_logs (worker_id, job_id, work_date);

-- ============================================================
-- TEST (_t22 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t22;
create temp table _t22(test text, result text, pass boolean);
do $$
declare
  cl  uuid := '00000000-0000-0000-0000-0000000f2201';
  wk  uuid := '00000000-0000-0000-0000-0000000f2202';
  jid uuid := 'ffff2201-2201-2201-2201-220122012201';
  clc text := json_build_object('sub','00000000-0000-0000-0000-0000000f2201','role','authenticated')::text;
  n int;
begin
  delete from auth.users where id in (cl,wk);
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',cl,'authenticated','authenticated','wl.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',wk,'authenticated','authenticated','wl.worker@dentmatch.local', now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic'),(wk,'worker') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิก wl','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (wk,'wl022','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.jobs(id,clinic_id,title,position,province) values (jid,cl,'งาน wl','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: clinic บันทึก worker เดียวกัน 2 "วันต่างกัน" → ได้ 2 แถว
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    insert into public.work_logs(clinic_id,worker_id,job_id,work_date,clinic_outcome) values (cl,wk,jid,'2026-06-10','came');
    insert into public.work_logs(clinic_id,worker_id,job_id,work_date,clinic_outcome) values (cl,wk,jid,'2026-06-12','came');
    execute 'reset role';
    select count(*) into n from public.work_logs where worker_id=wk and job_id=jid;
    insert into _t22 values ('บันทึก 2 วันต่างกัน (worker เดียว)', n::text||' แถว', n=2);
  exception when others then execute 'reset role'; insert into _t22 values ('บันทึก 2 วันต่างกัน','EXC:'||sqlerrm,false); end;

  -- T2: บันทึกซ้ำ "วันเดิม" → unique violation (กันซ้ำ)
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    insert into public.work_logs(clinic_id,worker_id,job_id,work_date,clinic_outcome) values (cl,wk,jid,'2026-06-10','came');
    execute 'reset role'; insert into _t22 values ('บันทึกซ้ำวันเดิม (ต้องกัน)','NO ERROR (dup!)',false);
  exception when others then execute 'reset role'; insert into _t22 values ('บันทึกซ้ำวันเดิม (ต้องกัน)','blocked ✓',true); end;

  delete from auth.users where id in (cl,wk);
end $$;
select * from _t22;
