-- DentMatch — 0007 · clinics.phone (เบอร์ติดต่อธุรกิจ · คลินิกแก้เองได้)
-- รันหลัง 0001-0006
-- privacy: phone = เบอร์ธุรกิจ (ไม่ใช่ PII ส่วนตัวเหมือน worker) · worker ไม่เห็น เพราะ query ฝั่ง worker
--          (บอร์ด/detail/inbox) select แค่ name/province/district/line_id/about — ไม่ขอ phone (app discipline)
--          คลินิกอ่าน phone ของตัวเอง = query clinics row ตัวเอง (รวม phone)

alter table public.clinics add column if not exists phone text;

-- GRANT update (ADDITIVE) : คลินิกแก้ line_id/about (0001) + phone (ใหม่)
-- name/province/district = admin-locked → ไม่อยู่ใน update grant → คลินิกแก้ไม่ได้ (lock คงเดิม)
grant update (phone) on public.clinics to authenticated;

-- ============================================================
-- TEST (_t7 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t7;
create temp table _t7(test text, result text, pass boolean);
do $$
declare cl uuid := '00000000-0000-0000-0000-0000000000f5';
        clc text := json_build_object('sub','00000000-0000-0000-0000-0000000000f5','role','authenticated')::text;
        r int; ph text; nm text;
begin
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',cl,'authenticated','authenticated','clinic.phone@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิกทดสอบ phone','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: clinic แก้ line_id + phone → ได้
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.clinics set line_id='@newline', phone='081-111-2222' where id=auth.uid();
    get diagnostics r=row_count; execute 'reset role';
    select phone into ph from public.clinics where id=cl;
    insert into _t7 values ('clinic UPDATE line_id+phone (allowed)', r::text||' row · phone='||coalesce(ph,'∅'), r>=1 and ph='081-111-2222');
  exception when others then execute 'reset role'; insert into _t7 values ('clinic UPDATE line_id+phone','EXC:'||sqlerrm,false); end;

  -- T2: clinic แก้ name → ต้อง ERROR (admin-locked · ไม่อยู่ใน grant)
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.clinics set name='ชื่อใหม่' where id=auth.uid();
    execute 'reset role'; insert into _t7 values ('clinic UPDATE name (ต้อง fail/lock)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t7 values ('clinic UPDATE name (ต้อง fail/lock)','errored ✓',true); end;

  -- T3: clinic แก้ province → ต้อง ERROR (admin-locked)
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.clinics set province='เชียงใหม่' where id=auth.uid();
    execute 'reset role'; insert into _t7 values ('clinic UPDATE province (ต้อง fail/lock)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t7 values ('clinic UPDATE province (ต้อง fail/lock)','errored ✓',true); end;

  -- T4: clinic อ่าน phone ของตัวเอง → ได้
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    select phone into ph from public.clinics where id=auth.uid();
    execute 'reset role';
    insert into _t7 values ('clinic อ่าน phone ตัวเอง', 'phone='||coalesce(ph,'∅'), ph='081-111-2222');
  exception when others then execute 'reset role'; insert into _t7 values ('clinic อ่าน phone','EXC:'||sqlerrm,false); end;

  delete from auth.users where id = cl;
end $$;
select * from _t7;
