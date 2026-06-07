-- DentMatch — 0020 · invites.read_at (สถานะ "อ่านแล้ว" จริง — worker เปิดดูคำเชิญ)
-- รันหลัง 0001-0019
-- เดิม "อ่านแล้ว" ฝั่งคลินิก = status='accepted' (= worker กดบันทึก) → แค่เปิดดูไม่นับ
-- ใหม่: worker เปิดแท็บคำเชิญ → set read_at → คลินิกเห็น "อ่านแล้ว" (read receipt จริง)
-- inv_upd (0001) อนุญาต worker_id=auth.uid update row ตัวเอง + ไม่มี revoke update → default grant ครอบคอลัมน์ใหม่

alter table public.invites add column if not exists read_at timestamptz;

-- ============================================================
-- TEST (_t20 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t20;
create temp table _t20(test text, result text, pass boolean);
do $$
declare
  ca  uuid := '00000000-0000-0000-0000-0000000f2001';   -- clinic (ผู้ส่ง)
  wk  uuid := '00000000-0000-0000-0000-0000000f2002';   -- worker (ผู้รับ)
  xx  uuid := '00000000-0000-0000-0000-0000000f2003';   -- คนนอก
  iid uuid;
  wkc text := json_build_object('sub','00000000-0000-0000-0000-0000000f2002','role','authenticated')::text;
  xxc text := json_build_object('sub','00000000-0000-0000-0000-0000000f2003','role','authenticated')::text;
  r int; ra timestamptz;
begin
  delete from auth.users where id in (ca,wk,xx);
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',ca,'authenticated','authenticated','ir.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',wk,'authenticated','authenticated','ir.worker@dentmatch.local', now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',xx,'authenticated','authenticated','ir.other@dentmatch.local',  now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (ca,'clinic'),(wk,'worker'),(xx,'worker') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (ca,'คลินิก ir','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (wk,'ir020','assistant','กรุงเทพมหานคร'),(xx,'ir021','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.invites(clinic_id,worker_id,status) values (ca,wk,'pending') returning id into iid;

  -- T1: worker (ผู้รับ) set read_at row ตัวเอง → ได้
  begin
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    update public.invites set read_at=now() where id=iid;
    get diagnostics r=row_count; execute 'reset role';
    select read_at into ra from public.invites where id=iid;
    insert into _t20 values ('worker set read_at คำเชิญตัวเอง', r::text||' row · read_at='||(case when ra is null then '∅' else 'set' end), r>=1 and ra is not null);
  exception when others then execute 'reset role'; insert into _t20 values ('worker set read_at','EXC:'||sqlerrm,false); end;

  -- T2: คนนอก (worker อื่น) set read_at คำเชิญนี้ → 0 row (RLS กัน)
  begin
    perform set_config('request.jwt.claims', xxc, true); execute 'set local role authenticated';
    update public.invites set read_at=now() where id=iid;
    get diagnostics r=row_count; execute 'reset role';
    insert into _t20 values ('คนนอก set read_at (ต้อง 0 row)', r::text||' row', r=0);
  exception when others then execute 'reset role'; insert into _t20 values ('คนนอก set read_at','EXC:'||sqlerrm,false); end;

  delete from auth.users where id in (ca,wk,xx);
end $$;
select * from _t20;
