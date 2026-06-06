-- DentMatch — 0008 · worker_profiles.provinces text[] (รับงานได้หลายจังหวัด)
-- รันหลัง 0001-0007
-- เก็บ province (เดิม · ตัวหลัก = provinces[0]) ไว้ backward-compat (การ์ด/filter เดิม) + เพิ่ม provinces[] (ครบทุกจังหวัด)

alter table public.worker_profiles add column if not exists provinces text[] not null default '{}';

-- backfill: คนเดิมที่มี province เดี่ยว → provinces = [province]
update public.worker_profiles
  set provinces = array[province]
  where province is not null and coalesce(array_length(provinces,1),0)=0;

-- GRANT update (ADDITIVE) : worker แก้เองได้ (อยู่กลุ่มเดียวกับ province/skills/... ตาม 0001/0003)
grant update (provinces) on public.worker_profiles to authenticated;

-- ============================================================
-- TEST (_t8 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t8;
create temp table _t8(test text, result text, pass boolean);
do $$
declare uid uuid := '00000000-0000-0000-0000-0000000000f6';
        claims text := json_build_object('sub','00000000-0000-0000-0000-0000000000f6','role','authenticated')::text;
        arr text[]; n int;
begin
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated','prov.test@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (uid,'worker') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (uid,'provx','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T0: backfill logic (รันกับ test worker เอง — เพราะ insert หลัง migration backfill ทำงานไปแล้ว)
  update public.worker_profiles set provinces=array[province] where id=uid and coalesce(array_length(provinces,1),0)=0;
  select provinces into arr from public.worker_profiles where id=uid;
  insert into _t8 values ('backfill provinces = [province]', array_to_string(arr,','), arr = array['กรุงเทพมหานคร']);

  -- T1: worker แก้ provinces (หลายจังหวัด) → ได้
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    update public.worker_profiles set provinces = array['กรุงเทพมหานคร','ชลบุรี','นนทบุรี'] where id=auth.uid();
    get diagnostics n=row_count; execute 'reset role';
    select provinces into arr from public.worker_profiles where id=uid;
    insert into _t8 values ('worker UPDATE provinces (หลายจังหวัด)', n::text||' row · '||array_to_string(arr,','), n>=1 and array_length(arr,1)=3);
  exception when others then execute 'reset role'; insert into _t8 values ('worker UPDATE provinces','EXC:'||sqlerrm,false); end;

  -- T2: trust_score ยังบล็อก (ยืนยันไม่เผลอ re-grant)
  begin
    perform set_config('request.jwt.claims', claims, true); execute 'set local role authenticated';
    update public.worker_profiles set trust_score=999 where id=auth.uid();
    execute 'reset role'; insert into _t8 values ('trust_score ยัง block (ไม่ re-grant หลุด)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t8 values ('trust_score ยัง block','errored ✓',true); end;

  delete from auth.users where id = uid;
end $$;
select * from _t8;
