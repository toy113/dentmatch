-- DentMatch — 0004 · job display fields + ปิดช่อง boost ฟรีตอน INSERT
-- รันหลัง 0001-0003 · ให้การ์ดงาน .jcard render ของจริงครบ 100%

alter table public.jobs
  add column if not exists skills      text[] not null default '{}',
  add column if not exists work_days   int[]  not null default '{}',   -- 1=จ … 7=อา (ตรง day chips + filter)
  add column if not exists time_start  text,                            -- '09:00'
  add column if not exists time_end    text;                            -- '17:00'

-- UPDATE grant (ADDITIVE) : คลินิกแก้ 4 คอลัมน์ใหม่ได้ · is_boosted ยัง revoke ตาม 0001
grant update (skills, work_days, time_start, time_end) on public.jobs to authenticated;

-- ★ INSERT column-grant : กัน client insert is_boosted=true (boost ฟรี) — มาเป็น default(false) เท่านั้น
-- (0001 revoke เฉพาะ UPDATE ; INSERT ยังเปิดทุกคอลัมน์ → ปิดที่นี่)
revoke insert on public.jobs from authenticated;
grant  insert (clinic_id, title, position, province, district, wage_text, work_date, urgent, is_open, skills, work_days, time_start, time_end)
  on public.jobs to authenticated;
-- is_boosted (+ id/created_at) ไม่อยู่ในลิสต์ = client insert ไม่ได้ → default false ; service_role/admin ยัง set ได้

-- ============================================================
-- TEST (ผลเป็นตาราง _t4 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t4;
create temp table _t4(test text, result text, pass boolean);
do $$
declare uid uuid := '00000000-0000-0000-0000-0000000000f1';
        claims text := json_build_object('sub','00000000-0000-0000-0000-0000000000f1','role','authenticated')::text; r int; b boolean;
begin
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated','job.test@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (uid,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (uid,'คลินิกทดสอบงาน','กรุงเทพมหานคร') on conflict (id) do nothing;
  -- job สำหรับ test update (insert เป็น owner)
  insert into public.jobs(id,clinic_id,title,position,province) values ('22222222-2222-2222-2222-222222222222',uid,'งานทดสอบ','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: clinic insert job พร้อม is_boosted=true → ต้อง ERROR
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province,is_boosted) values (uid,'boostฟรี','assistant','กรุงเทพมหานคร',true);
    execute 'reset role'; insert into _t4 values ('clinic INSERT is_boosted=true (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t4 values ('clinic INSERT is_boosted=true (ต้อง fail)','errored ✓',true); end;

  -- T2: clinic insert job ปกติ (ไม่ใส่ is_boosted) → OK + is_boosted=false
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province) values (uid,'งานปกติ','assistant','กรุงเทพมหานคร');   -- ไม่ใส่ id (ปล่อย default) เหมือน client จริง
    execute 'reset role';
    select is_boosted into b from public.jobs where clinic_id=uid and title='งานปกติ' order by created_at desc limit 1;
    insert into _t4 values ('clinic INSERT ปกติ → is_boosted default false', 'is_boosted='||b::text, b=false);
  exception when others then execute 'reset role'; insert into _t4 values ('clinic INSERT ปกติ','EXC:'||sqlerrm,false); end;

  -- T3: clinic update is_boosted=true → ต้อง ERROR (UPDATE ยัง revoke)
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    update public.jobs set is_boosted=true where clinic_id=auth.uid();
    execute 'reset role'; insert into _t4 values ('clinic UPDATE is_boosted=true (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t4 values ('clinic UPDATE is_boosted=true (ต้อง fail)','errored ✓',true); end;

  -- T4: clinic update skills/work_days/time → ได้
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    update public.jobs set skills='{GP,Implant}', work_days='{6,7}', time_start='09:00', time_end='17:00' where clinic_id=auth.uid();
    get diagnostics r=row_count; execute 'reset role';
    insert into _t4 values ('clinic UPDATE skills/work_days/time (allowed)', r::text||' row', r>=1);
  exception when others then execute 'reset role'; insert into _t4 values ('clinic UPDATE skills/work_days/time','EXC:'||sqlerrm,false); end;

  delete from auth.users where id = uid;
end $$;
select * from _t4;
