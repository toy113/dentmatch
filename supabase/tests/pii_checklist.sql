-- DentMatch — PII / RLS / column-lock test (C1 · Batch 1 gate) · ONE-SHOT self-checking
-- รันใน Supabase SQL Editor หลัง 0001_dentmatch_init.sql
-- ✅ ก๊อปทั้งไฟล์ → กด Run ครั้งเดียว → ดูตารางผลท้ายสุด: คอลัมน์ pass ต้องเป็น true ครบทุกแถว
--    ถ้ามี false แถวไหน = จุดที่ RLS/column-lock รั่ว
-- UUID ทดสอบคงที่: clinic=...c1 · workerA=...a1 · workerB=...b1

-- ========== TEARDOWN (เผื่อรอบก่อนค้าง) + SEED (owner) ==========
delete from auth.users where id in (
  '00000000-0000-0000-0000-0000000000c1',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000b1');

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
values
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000000c1','authenticated','authenticated','clinic.test@dentmatch.local', now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000000a1','authenticated','authenticated','workerA.test@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000000b1','authenticated','authenticated','workerB.test@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
on conflict (id) do nothing;

insert into public.profiles (id, role) values
  ('00000000-0000-0000-0000-0000000000c1','clinic'),
  ('00000000-0000-0000-0000-0000000000a1','worker'),
  ('00000000-0000-0000-0000-0000000000b1','worker');
insert into public.clinics (id, name, province) values
  ('00000000-0000-0000-0000-0000000000c1','คลินิกทดสอบ','กรุงเทพมหานคร');
insert into public.worker_profiles (id, anon_id, position, province) values
  ('00000000-0000-0000-0000-0000000000a1','seedA','assistant','กรุงเทพมหานคร'),
  ('00000000-0000-0000-0000-0000000000b1','seedB','assistant','นนทบุรี');
insert into public.worker_private (worker_id, first_name, last_name, phone) values
  ('00000000-0000-0000-0000-0000000000a1','สมชาย','ใจดี','0810000001'),
  ('00000000-0000-0000-0000-0000000000b1','สมหญิง','รักงาน','0810000002');
insert into public.worker_license (worker_id, license_no) values
  ('00000000-0000-0000-0000-0000000000a1','T-A-12345'),
  ('00000000-0000-0000-0000-0000000000b1','T-B-67890');
insert into public.jobs (id, clinic_id, title, position, province) values
  ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000c1','งานทดสอบ','assistant','กรุงเทพมหานคร');
insert into public.add_line_events (worker_id, clinic_id) values
  ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000c1');

-- ========== RESULTS TABLE ==========
drop table if exists _test_results;
create temp table _test_results(n int, name text, expected text, actual text, pass boolean);

-- ========== TESTS (one DO block) ==========
do $$
declare
  v_c text := '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}';
  v_a text := '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
  v_b text := '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
  i int; r int; s text; bl boolean; p text;
begin
  -- ---- (ก) คลินิก: อ่าน ----
  begin
    perform set_config('request.jwt.claims', v_c, true); execute 'set local role authenticated';
    select count(*) into i from public.worker_private; execute 'reset role';
    insert into _test_results values (2,'clinic reads worker_private','0',i::text,i=0);
  exception when others then execute 'reset role';
    insert into _test_results values (2,'clinic reads worker_private','0','EXC:'||sqlerrm,false); end;

  begin
    perform set_config('request.jwt.claims', v_c, true); execute 'set local role authenticated';
    select count(*) into i from public.worker_license; execute 'reset role';
    insert into _test_results values (3,'clinic reads worker_license','0',i::text,i=0);
  exception when others then execute 'reset role';
    insert into _test_results values (3,'clinic reads worker_license','0','EXC:'||sqlerrm,false); end;

  begin
    perform set_config('request.jwt.claims', v_c, true); execute 'set local role authenticated';
    select count(*) into i from public.worker_profiles; execute 'reset role';
    insert into _test_results values (4,'clinic reads worker_profiles (public-safe)','2',i::text,i=2);
  exception when others then execute 'reset role';
    insert into _test_results values (4,'clinic reads worker_profiles','2','EXC:'||sqlerrm,false); end;

  begin
    perform set_config('request.jwt.claims', v_c, true); execute 'set local role authenticated';
    select count(*) into i from public.add_line_events; execute 'reset role';
    insert into _test_results values (5,'clinic reads add_line_events (own event)','1',i::text,i=1);
  exception when others then execute 'reset role';
    insert into _test_results values (5,'clinic reads add_line_events','1','EXC:'||sqlerrm,false); end;

  -- ---- (ก) คลินิก: update ที่ต้อง ERROR ----
  begin
    perform set_config('request.jwt.claims', v_c, true); execute 'set local role authenticated';
    update public.clinics set name='hack' where id=auth.uid(); execute 'reset role';
    insert into _test_results values (6,'clinic update clinics.name (locked)','ERROR','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role';
    insert into _test_results values (6,'clinic update clinics.name (locked)','ERROR','errored ✓',true); end;

  begin
    perform set_config('request.jwt.claims', v_c, true); execute 'set local role authenticated';
    update public.clinics set plan_tier='pro' where id=auth.uid(); execute 'reset role';
    insert into _test_results values (7,'clinic update clinics.plan_tier (server)','ERROR','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role';
    insert into _test_results values (7,'clinic update clinics.plan_tier (server)','ERROR','errored ✓',true); end;

  begin
    perform set_config('request.jwt.claims', v_c, true); execute 'set local role authenticated';
    update public.jobs set is_boosted=true where clinic_id=auth.uid(); execute 'reset role';
    insert into _test_results values (8,'clinic update jobs.is_boosted (server)','ERROR','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role';
    insert into _test_results values (8,'clinic update jobs.is_boosted (server)','ERROR','errored ✓',true); end;

  -- ---- (ก) คลินิก: update ที่ควรได้ ----
  begin
    perform set_config('request.jwt.claims', v_c, true); execute 'set local role authenticated';
    update public.clinics set about='ทดสอบ' where id=auth.uid(); get diagnostics r=row_count; execute 'reset role';
    insert into _test_results values (9,'clinic update clinics.about (allowed)','1 row',r::text,r=1);
  exception when others then execute 'reset role';
    insert into _test_results values (9,'clinic update clinics.about (allowed)','1 row','EXC:'||sqlerrm,false); end;

  -- ---- (ข) worker A แตะของ worker B ----
  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    select count(*) into i from public.worker_private where worker_id='00000000-0000-0000-0000-0000000000b1'; execute 'reset role';
    insert into _test_results values (10,'workerA reads worker_private of B','0',i::text,i=0);
  exception when others then execute 'reset role';
    insert into _test_results values (10,'workerA reads worker_private of B','0','EXC:'||sqlerrm,false); end;

  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    update public.worker_profiles set bio='hack' where id='00000000-0000-0000-0000-0000000000b1'; get diagnostics r=row_count; execute 'reset role';
    insert into _test_results values (11,'workerA updates bio of B (RLS blocks)','0 rows',r::text,r=0);
  exception when others then execute 'reset role';
    insert into _test_results values (11,'workerA updates bio of B','0 rows','EXC:'||sqlerrm,false); end;

  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    select count(*) into i from public.worker_license where worker_id='00000000-0000-0000-0000-0000000000b1'; execute 'reset role';
    insert into _test_results values (12,'workerA reads worker_license of B','0',i::text,i=0);
  exception when others then execute 'reset role';
    insert into _test_results values (12,'workerA reads worker_license of B','0','EXC:'||sqlerrm,false); end;

  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    select count(*) into i from public.add_line_events; execute 'reset role';
    insert into _test_results values (13,'workerA reads add_line_events (party)','1',i::text,i=1);
  exception when others then execute 'reset role';
    insert into _test_results values (13,'workerA reads add_line_events','1','EXC:'||sqlerrm,false); end;

  begin
    perform set_config('request.jwt.claims', v_b, true); execute 'set local role authenticated';
    select count(*) into i from public.add_line_events; execute 'reset role';
    insert into _test_results values (14,'workerB reads add_line_events (not party)','0',i::text,i=0);
  exception when others then execute 'reset role';
    insert into _test_results values (14,'workerB reads add_line_events','0','EXC:'||sqlerrm,false); end;

  -- ---- (ค) worker A แก้ฟิลด์ server ของตัวเอง: ต้อง ERROR ----
  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    update public.worker_profiles set trust_score=999 where id=auth.uid(); execute 'reset role';
    insert into _test_results values (15,'workerA set trust_score (server)','ERROR','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role';
    insert into _test_results values (15,'workerA set trust_score (server)','ERROR','errored ✓',true); end;

  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    update public.worker_profiles set license_verified=true where id=auth.uid(); execute 'reset role';
    insert into _test_results values (16,'workerA set license_verified (badge)','ERROR','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role';
    insert into _test_results values (16,'workerA set license_verified (badge)','ERROR','errored ✓',true); end;

  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    update public.worker_profiles set no_show_count=0 where id=auth.uid(); execute 'reset role';
    insert into _test_results values (17,'workerA set no_show_count (server)','ERROR','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role';
    insert into _test_results values (17,'workerA set no_show_count (server)','ERROR','errored ✓',true); end;

  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    update public.worker_license set verified=true where worker_id=auth.uid(); execute 'reset role';
    insert into _test_results values (18,'workerA set worker_license.verified','ERROR','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role';
    insert into _test_results values (18,'workerA set worker_license.verified','ERROR','errored ✓',true); end;

  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    update public.worker_profiles set position='dentist' where id=auth.uid(); execute 'reset role';
    insert into _test_results values (19,'workerA set position=dentist (no license)','ERROR','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role';
    insert into _test_results values (19,'workerA set position=dentist (no license)','ERROR','errored ✓',true); end;

  -- ---- (ค) worker A แก้ที่ควรได้ ----
  begin
    perform set_config('request.jwt.claims', v_a, true); execute 'set local role authenticated';
    update public.worker_profiles set bio='สวัสดี', district='บางรัก' where id=auth.uid(); get diagnostics r=row_count; execute 'reset role';
    insert into _test_results values (20,'workerA update bio/district (allowed)','1 row',r::text,r=1);
  exception when others then execute 'reset role';
    insert into _test_results values (20,'workerA update bio/district (allowed)','1 row','EXC:'||sqlerrm,false); end;

  -- ---- (ง) Trigger logic (owner — ทดสอบการคำนวณ) ----
  begin
    insert into public.work_logs(clinic_id,worker_id,work_date,clinic_outcome,worker_outcome)
      values('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000a1',current_date,'came','came');
    select trust_score||'|'||no_show_count into p from public.worker_profiles where id='00000000-0000-0000-0000-0000000000a1';
    insert into _test_results values (21,'trigger came+came -> trust','1|0',p,p='1|0');
  exception when others then
    insert into _test_results values (21,'trigger came+came -> trust','1|0','EXC:'||sqlerrm,false); end;

  begin
    insert into public.work_logs(clinic_id,worker_id,work_date,clinic_outcome,worker_outcome)
      values('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000a1',current_date,'no_show','came');
    select status into s from public.work_logs order by created_at desc limit 1;
    insert into _test_results values (22,'trigger outcome mismatch -> disputed','disputed',s,s='disputed');
  exception when others then
    insert into _test_results values (22,'trigger outcome mismatch -> disputed','disputed','EXC:'||sqlerrm,false); end;

  begin
    select count(*) into i from public.v_disputed_logs;
    insert into _test_results values (23,'v_disputed_logs has the disputed row','>=1',i::text,i>=1);
  exception when others then
    insert into _test_results values (23,'v_disputed_logs','>=1','EXC:'||sqlerrm,false); end;

  begin
    insert into public.work_logs(clinic_id,worker_id,work_date,clinic_outcome,worker_outcome)
      values('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000a1',current_date,'cancelled','cancelled');
    select trust_score||'|'||no_show_count into p from public.worker_profiles where id='00000000-0000-0000-0000-0000000000a1';
    insert into _test_results values (24,'cancelled not counted (trust/no_show)','1|0',p,p='1|0');
  exception when others then
    insert into _test_results values (24,'cancelled not counted','1|0','EXC:'||sqlerrm,false); end;

  begin
    update public.worker_license set verified=true, verified_at=now() where worker_id='00000000-0000-0000-0000-0000000000a1';
    select license_verified into bl from public.worker_profiles where id='00000000-0000-0000-0000-0000000000a1';
    insert into _test_results values (25,'verify license -> badge sync true','true',bl::text,bl=true);
  exception when others then
    insert into _test_results values (25,'verify license -> badge sync','true','EXC:'||sqlerrm,false); end;

  begin
    update public.worker_profiles set position='dentist' where id='00000000-0000-0000-0000-0000000000a1';
    select position into s from public.worker_profiles where id='00000000-0000-0000-0000-0000000000a1';
    insert into _test_results values (26,'dentist allowed after verified','dentist',s,s='dentist');
  exception when others then
    insert into _test_results values (26,'dentist allowed after verified','dentist','EXC:'||sqlerrm,false); end;

end $$;
reset role;

-- ========== TEARDOWN ==========
delete from auth.users where id in (
  '00000000-0000-0000-0000-0000000000c1',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000b1');

-- ========== ผลลัพธ์ (ดูแถวนี้) ==========
select n, name, expected, actual, pass from _test_results order by n;
-- ✅ ผ่าน = pass เป็น true ครบ 25 แถว (n 2-26) · false แถวไหน = จุดที่ต้องแก้
