-- DentMatch — 0021 · jobs.work_dates (เลือกวันที่เจาะจงได้หลายวัน)
-- รันหลัง 0001-0020
-- เดิม work_date = วันเดียว · เพิ่ม work_dates jsonb = array ['YYYY-MM-DD',...] (หลายวัน)
-- คง work_date ไว้ (= วันแรก/เร็วสุด) เพื่อ backward compat (การ์ด manage / _dmJobIsPast / work_log)
-- grant insert+update (work_dates) แบบ additive · jobs.j_cud RLS gate clinic_id=auth.uid อยู่แล้ว

alter table public.jobs add column if not exists work_dates jsonb;
grant insert (work_dates) on public.jobs to authenticated;
grant update (work_dates) on public.jobs to authenticated;

-- ============================================================
-- TEST (_t21 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t21;
create temp table _t21(test text, result text, pass boolean);
do $$
declare
  cl  uuid := '00000000-0000-0000-0000-0000000f2101';
  jid uuid;
  clc text := json_build_object('sub','00000000-0000-0000-0000-0000000f2101','role','authenticated')::text;
  wd jsonb; n int;
begin
  delete from auth.users where id = cl;
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',cl,'authenticated','authenticated','wd.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิก wd','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: clinic insert job + work_dates (หลายวัน) → ได้
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province,work_dates)
      values (cl,'งาน wd','assistant','กรุงเทพมหานคร','["2026-06-10","2026-06-12","2026-06-15"]'::jsonb) returning id into jid;
    execute 'reset role';
    select work_dates into wd from public.jobs where id=jid;
    insert into _t21 values ('clinic insert work_dates (3 วัน)', 'len='||coalesce(jsonb_array_length(wd)::text,'∅'), wd is not null and jsonb_array_length(wd)=3);
  exception when others then execute 'reset role'; insert into _t21 values ('clinic insert work_dates','EXC:'||sqlerrm,false); end;

  -- T2: clinic update work_dates → ได้
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.jobs set work_dates='["2026-07-01"]'::jsonb where id=jid;
    get diagnostics n=row_count; execute 'reset role';
    select work_dates into wd from public.jobs where id=jid;
    insert into _t21 values ('clinic update work_dates', n::text||' row · len='||jsonb_array_length(wd)::text, n>=1 and jsonb_array_length(wd)=1);
  exception when others then execute 'reset role'; insert into _t21 values ('clinic update work_dates','EXC:'||sqlerrm,false); end;

  delete from auth.users where id = cl;
end $$;
select * from _t21;
