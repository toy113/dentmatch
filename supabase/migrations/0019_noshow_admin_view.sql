-- DentMatch — 0019 · v_noshow_logs (admin view · no-show ฝ่ายเดียว)
-- รันหลัง 0001-0018
-- กลไกใหม่: no_show = คลินิกบันทึกฝ่ายเดียว (ไม่ดึง worker ยืนยัน) → admin ดูรายการผ่าน view นี้
-- admin-only (service_role) · revoke authenticated/anon (เหมือน v_disputed_logs) · join ชื่อ/anon ให้ดูง่าย

create or replace view public.v_noshow_logs as
  select l.id, l.work_date, l.status, l.created_at,
         l.clinic_id, c.name    as clinic_name,
         l.worker_id, w.anon_id as worker_anon,
         l.job_id,    j.title    as job_title
  from public.work_logs l
  left join public.clinics c         on c.id = l.clinic_id
  left join public.worker_profiles w on w.id = l.worker_id
  left join public.jobs j            on j.id = l.job_id
  where l.clinic_outcome = 'no_show'
  order by l.created_at desc;

revoke all on public.v_noshow_logs from authenticated, anon;

-- ============================================================
-- TEST (_t19 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t19;
create temp table _t19(test text, result text, pass boolean);
do $$
declare
  cl  uuid := '00000000-0000-0000-0000-0000000f1901';
  wk  uuid := '00000000-0000-0000-0000-0000000f1902';
  jid uuid := 'ffff1901-1901-1901-1901-190119011901';
  n int;
begin
  delete from auth.users where id in (cl,wk);
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',cl,'authenticated','authenticated','ns.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',wk,'authenticated','authenticated','ns.worker@dentmatch.local', now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic'),(wk,'worker') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิก ns','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (wk,'ns019','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.jobs(id,clinic_id,title,position,province) values (jid,cl,'งาน ns','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  -- คลินิกมาร์ก no_show ฝ่ายเดียว (owner-context insert · status=pending)
  insert into public.work_logs(clinic_id,worker_id,job_id,work_date,clinic_outcome) values (cl,wk,jid,current_date,'no_show');

  -- T1: admin (owner) เห็น no-show ใน view
  select count(*) into n from public.v_noshow_logs where worker_id=wk;
  insert into _t19 values ('admin เห็น no-show ใน view', n::text||' แถว', n>=1);

  -- T2: no_show_count ของ worker ยังเป็น 0 (ฝ่ายเดียว ไม่ confirmed → ไม่นับสาธารณะ)
  select no_show_count into n from public.worker_profiles where id=wk;
  insert into _t19 values ('no_show_count คง 0 (ไม่นับสาธารณะ)', n::text, n=0);

  -- T3: authenticated อ่าน view ไม่ได้ (revoked → admin-only)
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',cl::text,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    perform 1 from public.v_noshow_logs limit 1;
    execute 'reset role'; insert into _t19 values ('authenticated อ่าน view (ต้อง denied)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t19 values ('authenticated อ่าน view (ต้อง denied)','denied ✓',true); end;

  delete from auth.users where id in (cl,wk);
end $$;
select * from _t19;
