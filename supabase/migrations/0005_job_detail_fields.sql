-- DentMatch — 0005 · job detail fields (description + patients_per_day) ให้ v-job-detail render จริง
-- รันหลัง 0001-0004
-- หมายเหตุ: "ADD LINE แล้ว N คน" ไม่เพิ่มคอลัมน์ — derive จาก COUNT(add_line_events) ฝั่ง client (ยอดจริง)
--           ฟอร์มลงงาน (cc-post) ยังไม่เก็บ 2 ฟิลด์นี้ → เพิ่มช่องในฟอร์มตอน C3 ; ก่อนหน้านั้น detail บล็อกนี้ว่าง/ซ่อน

alter table public.jobs
  add column if not exists description      text,
  add column if not exists patients_per_day int;   -- จำนวนคนไข้โดยประมาณ/วัน

-- UPDATE grant (ADDITIVE) : คลินิกแก้ 2 คอลัมน์ใหม่ได้ · is_boosted ยัง revoke ตาม 0001/0004
grant update (description, patients_per_day) on public.jobs to authenticated;

-- ★ INSERT column-grant : re-grant ลิสต์เดิม (0004) + 2 คอลัมน์ใหม่ · ยัง exclude is_boosted (กัน boost ฟรี)
-- (revoke ก่อน grant = idempotent ; is_boosted/id/created_at ไม่อยู่ในลิสต์ = client insert ไม่ได้ → default)
revoke insert on public.jobs from authenticated;
grant  insert (clinic_id, title, position, province, district, wage_text, work_date, urgent, is_open,
               skills, work_days, time_start, time_end, description, patients_per_day)
  on public.jobs to authenticated;

-- ============================================================
-- TEST (ผลเป็นตาราง _t5 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t5;
create temp table _t5(test text, result text, pass boolean);
do $$
declare uid uuid := '00000000-0000-0000-0000-0000000000f2';
        claims text := json_build_object('sub','00000000-0000-0000-0000-0000000000f2','role','authenticated')::text;
        r int; b boolean; d text; pp int;
begin
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated','job5.test@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (uid,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (uid,'คลินิกทดสอบ detail','กรุงเทพมหานคร') on conflict (id) do nothing;
  -- job สำหรับ test update (insert เป็น owner ผ่าน superuser, ปล่อย default id)
  insert into public.jobs(id,clinic_id,title,position,province) values ('33333333-3333-3333-3333-333333333333',uid,'งานทดสอบ detail','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: clinic insert job พร้อม is_boosted=true → ต้อง ERROR (column ไม่อยู่ใน grant)
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province,is_boosted) values (uid,'boostฟรี','assistant','กรุงเทพมหานคร',true);
    execute 'reset role'; insert into _t5 values ('clinic INSERT is_boosted=true (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t5 values ('clinic INSERT is_boosted=true (ต้อง fail)','errored ✓',true); end;

  -- T2: clinic insert job ปกติ + description/patients_per_day (ไม่ใส่ id) → OK + is_boosted=false + ค่าถูกเก็บ
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province,description,patients_per_day)
      values (uid,'งานปกติ detail','assistant','กรุงเทพมหานคร','ช่วยงานทั่วไป ขูดหินปูน',12);
    execute 'reset role';
    select is_boosted, description, patients_per_day into b,d,pp
      from public.jobs where clinic_id=uid and title='งานปกติ detail' order by created_at desc limit 1;
    insert into _t5 values ('clinic INSERT + description/patients_per_day',
      'is_boosted='||b::text||' desc='||coalesce(d,'∅')||' ppd='||coalesce(pp::text,'∅'),
      (b=false and d='ช่วยงานทั่วไป ขูดหินปูน' and pp=12));
  exception when others then execute 'reset role'; insert into _t5 values ('clinic INSERT + description/patients_per_day','EXC:'||sqlerrm,false); end;

  -- T3: clinic update is_boosted=true → ต้อง ERROR (UPDATE ยัง revoke)
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    update public.jobs set is_boosted=true where clinic_id=auth.uid();
    execute 'reset role'; insert into _t5 values ('clinic UPDATE is_boosted=true (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t5 values ('clinic UPDATE is_boosted=true (ต้อง fail)','errored ✓',true); end;

  -- T4: clinic update description/patients_per_day → ได้
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    update public.jobs set description='แก้ไขแล้ว', patients_per_day=20 where clinic_id=auth.uid();
    get diagnostics r=row_count; execute 'reset role';
    insert into _t5 values ('clinic UPDATE description/patients_per_day (allowed)', r::text||' row', r>=1);
  exception when others then execute 'reset role'; insert into _t5 values ('clinic UPDATE description/patients_per_day','EXC:'||sqlerrm,false); end;

  delete from auth.users where id = uid;
end $$;
select * from _t5;
