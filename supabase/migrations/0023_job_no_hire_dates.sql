-- DentMatch — 0023 · jobs.no_hire_dates (วันที่คลินิกกด "ยังหาคนอยู่" สำหรับวันที่ผ่านแล้ว)
-- รันหลัง 0001-0022
-- บริบท: งานหลายวัน (work_dates) · เดิม "ยังหาคนอยู่" (finding) ไม่บันทึกอะไรเลย →
--   วันที่ผ่านแล้วยังถูกนับว่า "ยังไม่บันทึก" ค้าง (การ์ดโชว์ 0/N + เตือนซ้ำ)
-- แก้: เก็บวันที่ "ปิดโดยไม่ได้จ้างใคร" ใน jobs.no_hire_dates jsonb = ['YYYY-MM-DD',...]
--   การนับ "บันทึก X/N" + เตือน "วันที่ผ่านแล้ว" จะถือว่าวันเหล่านี้ "บันทึกแล้ว"
-- ปลอดภัย: เป็น annotation ระดับงาน · ไม่แตะ work_logs / trust_score / no_show_count เลย
-- no_hire_dates = clinic-controlled (ไม่ใช่ protected) → GRANT update additive (ไม่เปิด INSERT · default null)
-- jobs.j_cud RLS gate clinic_id=auth.uid อยู่แล้ว (0001)

alter table public.jobs add column if not exists no_hire_dates jsonb;
grant update (no_hire_dates) on public.jobs to authenticated;

-- ============================================================
-- TEST (_t23 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t23;
create temp table _t23(test text, result text, pass boolean);
do $$
declare
  cl  uuid := '00000000-0000-0000-0000-0000000f2301';
  oth uuid := '00000000-0000-0000-0000-0000000f2302';
  jid uuid;
  clc text := json_build_object('sub','00000000-0000-0000-0000-0000000f2301','role','authenticated')::text;
  otc text := json_build_object('sub','00000000-0000-0000-0000-0000000f2302','role','authenticated')::text;
  nh jsonb; n int;
begin
  delete from auth.users where id in (cl,oth);
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',cl, 'authenticated','authenticated','nh.clinic@dentmatch.local', now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',oth,'authenticated','authenticated','nh.other@dentmatch.local',  now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic'),(oth,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิก nh','กรุงเทพมหานคร'),(oth,'คลินิก other','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- เตรียมงานของ cl
  perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
  insert into public.jobs(clinic_id,title,position,province,work_dates)
    values (cl,'งาน nh','assistant','กรุงเทพมหานคร','["2026-06-04","2026-06-07","2026-06-11"]'::jsonb) returning id into jid;
  execute 'reset role';

  -- T1: clinic เจ้าของ update no_hire_dates → ได้
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.jobs set no_hire_dates='["2026-06-04"]'::jsonb where id=jid;
    get diagnostics n=row_count; execute 'reset role';
    select no_hire_dates into nh from public.jobs where id=jid;
    insert into _t23 values ('clinic update no_hire_dates', n::text||' row · len='||coalesce(jsonb_array_length(nh)::text,'∅'), n>=1 and nh is not null and jsonb_array_length(nh)=1);
  exception when others then execute 'reset role'; insert into _t23 values ('clinic update no_hire_dates','EXC:'||sqlerrm,false); end;

  -- T2: clinic เจ้าของ append วันที่สอง → len=2
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.jobs set no_hire_dates='["2026-06-04","2026-06-07"]'::jsonb where id=jid;
    get diagnostics n=row_count; execute 'reset role';
    select no_hire_dates into nh from public.jobs where id=jid;
    insert into _t23 values ('append วันที่สอง', 'len='||jsonb_array_length(nh)::text, n>=1 and jsonb_array_length(nh)=2);
  exception when others then execute 'reset role'; insert into _t23 values ('append วันที่สอง','EXC:'||sqlerrm,false); end;

  -- T3: คลินิกอื่น (ไม่ใช่เจ้าของ) update no_hire_dates → ต้องโดน RLS กั้น (0 row)
  begin
    perform set_config('request.jwt.claims', otc, true); execute 'set local role authenticated';
    update public.jobs set no_hire_dates='["2026-06-11"]'::jsonb where id=jid;
    get diagnostics n=row_count; execute 'reset role';
    insert into _t23 values ('คลินิกอื่นแก้ไม่ได้ (RLS)', n::text||' row', n=0);
  exception when others then execute 'reset role'; insert into _t23 values ('คลินิกอื่นแก้ไม่ได้ (RLS)','EXC:'||sqlerrm,false); end;

  -- cleanup
  delete from public.jobs where id=jid;
  delete from auth.users where id in (cl,oth);
end $$;
select * from _t23;
