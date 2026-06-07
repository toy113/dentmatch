-- DentMatch — 0015 · jobs.filled (แยกสถานะ "ได้คนแล้ว" ออกจาก "ปิดรับ/พัก")
-- รันหลัง 0001-0014
-- โมเดล: "ได้คนแล้ว" = filled=true + is_open=false (ปิดจากบอร์ด) · "ปิดรับ/พัก" = is_open=false + filled=false
--   การ์ด manage แยกสี/สถานะ (ได้คนแล้ว=ฟ้า / ปิดรับ=แดง) · filled → ปุ่ม "ลงบันทึกงาน" (เข้า flow trust C3d-2)
--   "เปิดรับใหม่" = filled=false + is_open=true
-- filled = clinic-controlled (ไม่ใช่ protected) → GRANT update additive · ไม่เปิด INSERT (default false กัน client ปลอม)

alter table public.jobs add column if not exists filled boolean not null default false;

-- GRANT update (ADDITIVE) : คลินิกเซ็ต filled เองได้ (กลุ่มเดียวกับ is_open) · ไม่อยู่ใน INSERT grant → default false
grant update (filled) on public.jobs to authenticated;

-- ============================================================
-- TEST (_t15 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t15;
create temp table _t15(test text, result text, pass boolean);
do $$
declare cl  uuid := '00000000-0000-0000-0000-0000000f1501';
        clc text := json_build_object('sub','00000000-0000-0000-0000-0000000f1501','role','authenticated')::text;
        jid uuid := 'ffff1501-1501-1501-1501-150115011501';
        b boolean; r int;
begin
  delete from auth.users where id = cl;
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',cl,'authenticated','authenticated','filled.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิก filled','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.jobs(id,clinic_id,title,position,province) values (jid,cl,'งาน filled test','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: filled default false (insert เป็น owner)
  select filled into b from public.jobs where id=jid;
  insert into _t15 values ('jobs.filled default false', 'filled='||coalesce(b::text,'∅'), b=false);

  -- T2: clinic UPDATE filled=true + is_open=false ("ได้คนแล้ว") → ได้ (อยู่ใน grant)
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.jobs set filled=true, is_open=false where id=jid;
    get diagnostics r=row_count; execute 'reset role';
    select filled into b from public.jobs where id=jid;
    insert into _t15 values ('clinic UPDATE filled=true (ได้คนแล้ว)', r::text||' row · filled='||b::text, r>=1 and b=true);
  exception when others then execute 'reset role'; insert into _t15 values ('clinic UPDATE filled=true','EXC:'||sqlerrm,false); end;

  -- T3: clinic UPDATE filled=false + is_open=true ("เปิดรับใหม่") → ได้
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.jobs set filled=false, is_open=true where id=jid;
    get diagnostics r=row_count; execute 'reset role';
    select filled into b from public.jobs where id=jid;
    insert into _t15 values ('clinic UPDATE filled=false (เปิดรับใหม่)', r::text||' row · filled='||b::text, r>=1 and b=false);
  exception when others then execute 'reset role'; insert into _t15 values ('clinic UPDATE filled=false','EXC:'||sqlerrm,false); end;

  -- T4: client INSERT filled=true → ต้อง ERROR (ไม่อยู่ใน INSERT grant → ปลอม filled ตอน insert ไม่ได้)
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province,filled) values (cl,'แอบ filled','assistant','กรุงเทพมหานคร',true);
    execute 'reset role'; insert into _t15 values ('client INSERT filled=true (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t15 values ('client INSERT filled=true (ต้อง fail)','errored ✓',true); end;

  delete from auth.users where id = cl;
end $$;
select * from _t15;
