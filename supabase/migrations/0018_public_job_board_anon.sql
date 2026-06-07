-- DentMatch — 0018 · เปิดบอร์ดงานสาธารณะให้ guest (anon) อ่านได้
-- รันหลัง 0001-0017
-- ปัญหา: j_sel / c_sel เป็น "to authenticated" → guest (anon) อ่าน jobs/clinics ไม่ได้ → บอร์ดเห็น "0 งาน"
--        (แอปเรียก dmLoadJobsBoard ให้ guest อยู่แล้ว แต่ RLS ปิด)
-- แก้: เพิ่ม policy ให้ anon select jobs (เป็น public listing) + clinics เฉพาะคอลัมน์ public
--   · line_id เปิดให้ anon (บอร์ด join ใช้ · เป็น contact ธุรกิจ) · phone ไม่เปิด (กัน leak ตาม 0007)
--   · jobs ไม่มี PII · worker_profiles ยังปิด anon เหมือนเดิม (guest เห็นบุคลากรเป็น teaser/mock)

-- jobs: public listing → anon อ่านได้
drop policy if exists j_sel_anon on public.jobs;
create policy j_sel_anon on public.jobs for select to anon using (true);

-- clinics: anon อ่านเฉพาะคอลัมน์ public (ไม่รวม phone)
drop policy if exists c_sel_anon on public.clinics;
create policy c_sel_anon on public.clinics for select to anon using (true);
revoke select on public.clinics from anon;
grant select (id, name, province, district, about, line_id) on public.clinics to anon;

-- ============================================================
-- TEST (_t18 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t18;
create temp table _t18(test text, result text, pass boolean);
do $$
declare
  ca uuid := '00000000-0000-0000-0000-0000000d1801';
  jb uuid := 'ffff1801-1801-1801-1801-180118011801';
  n int; ok boolean;
begin
  delete from auth.users where id = ca;
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',ca,'authenticated','authenticated','pjb.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (ca,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province,phone) values (ca,'คลินิก pjb','กรุงเทพมหานคร','081-000-0000') on conflict (id) do nothing;
  insert into public.jobs(id,clinic_id,title,position,province,is_open) values (jb,ca,'งาน pjb test','assistant','กรุงเทพมหานคร',true) on conflict (id) do nothing;

  -- T1: anon อ่าน jobs (เปิดรับ) → เห็น ≥1
  begin
    execute 'set local role anon';
    select count(*) into n from public.jobs where is_open=true and id=jb; execute 'reset role';
    insert into _t18 values ('anon อ่าน jobs ที่เปิดรับ', n::text||' แถว', n>=1);
  exception when others then execute 'reset role'; insert into _t18 values ('anon อ่าน jobs','EXC:'||sqlerrm,false); end;

  -- T2: anon อ่าน clinics คอลัมน์ public (name) → ได้
  begin
    execute 'set local role anon';
    select count(*) into n from (select id,name,province,district,about,line_id from public.clinics where id=ca) q; execute 'reset role';
    insert into _t18 values ('anon อ่าน clinics(public cols)', n::text||' แถว', n>=1);
  exception when others then execute 'reset role'; insert into _t18 values ('anon อ่าน clinics public','EXC:'||sqlerrm,false); end;

  -- T3: anon อ่าน clinics.phone → ต้อง permission denied (กัน leak)
  begin
    execute 'set local role anon';
    perform phone from public.clinics where id=ca; execute 'reset role';
    insert into _t18 values ('anon อ่าน clinics.phone (ต้อง denied)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t18 values ('anon อ่าน clinics.phone (ต้อง denied)','denied ✓',true); end;

  delete from auth.users where id = ca;
end $$;
select * from _t18;
