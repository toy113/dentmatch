-- DentMatch — 0014 · profile_views (นับ "โปรไฟล์ถูกดู" จริง · unique viewer)
-- รันหลัง 0001-0013  (0013_worker_counts_public = guest teaser · คนละเรื่องกับไฟล์นี้)
-- โมเดล: คลินิก(viewer) เปิดหน้า worker detail → log 1 แถวต่อ (worker, viewer)
--   · count = จำนวนคลินิกที่เคยดู (distinct · กันปั่นด้วย refresh เพราะ unique)
--   · worker เห็นเฉพาะยอดของตัวเอง (RLS) · viewer log ได้เฉพาะในนามตัวเอง · กัน self-view
--   · ไม่ realtime (derive ตอนโหลดโปรไฟล์) · ไม่แตะ protected fields

create table if not exists public.profile_views (
  id         uuid primary key default gen_random_uuid(),
  worker_id  uuid not null references public.worker_profiles(id) on delete cascade,
  viewer_id  uuid not null references public.profiles(id)        on delete cascade,
  created_at timestamptz not null default now(),
  unique (worker_id, viewer_id)   -- 1 viewer = 1 view (index นี้ครอบ count by worker_id ด้วย)
);

alter table public.profile_views enable row level security;

-- RLS: viewer insert ในนามตัวเอง + ห้าม self-view ; worker อ่านยอดตัวเอง (admin อ่านได้หมด)
create policy pv_ins on public.profile_views for insert to authenticated
  with check (viewer_id = auth.uid() and viewer_id <> worker_id);
create policy pv_sel on public.profile_views for select to authenticated
  using (worker_id = auth.uid() or public.is_admin());

-- column GRANT: viewer insert ได้แค่ (worker_id, viewer_id) · select RLS-gated · ไม่มี update/delete
-- (revoke ก่อน = กัน default-privilege ของ Supabase ที่ grant กว้างให้ authenticated/anon)
revoke all on public.profile_views from authenticated, anon;
grant select on public.profile_views to authenticated;
grant insert (worker_id, viewer_id) on public.profile_views to authenticated;

-- ============================================================
-- TEST (_t14 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t14;
create temp table _t14(test text, result text, pass boolean);
do $$
declare
  wk uuid := '00000000-0000-0000-0000-0000000d1301';   -- worker (ถูกดู)
  ca uuid := '00000000-0000-0000-0000-0000000d1302';   -- clinic A (viewer)
  cb uuid := '00000000-0000-0000-0000-0000000d1303';   -- clinic B (อีกคน)
  wkc text := json_build_object('sub','00000000-0000-0000-0000-0000000d1301','role','authenticated')::text;
  cac text := json_build_object('sub','00000000-0000-0000-0000-0000000d1302','role','authenticated')::text;
  cbc text := json_build_object('sub','00000000-0000-0000-0000-0000000d1303','role','authenticated')::text;
  n int;
begin
  delete from auth.users where id in (wk,ca,cb);
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',wk,'authenticated','authenticated','pv.worker@dentmatch.local', now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',ca,'authenticated','authenticated','pv.clinicA@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',cb,'authenticated','authenticated','pv.clinicB@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (wk,'worker'),(ca,'clinic'),(cb,'clinic') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (wk,'pv014','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (ca,'คลินิก A','กรุงเทพมหานคร'),(cb,'คลินิก B','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: clinic A log view → OK
  begin
    perform set_config('request.jwt.claims', cac, true); execute 'set local role authenticated';
    insert into public.profile_views(worker_id, viewer_id) values (wk, ca);
    execute 'reset role'; insert into _t14 values ('clinic A log view (insert)','ok ✓',true);
  exception when others then execute 'reset role'; insert into _t14 values ('clinic A log view (insert)','EXC:'||sqlerrm,false); end;

  -- T2: clinic A log ซ้ำ (worker เดิม) → unique violation = dedup
  begin
    perform set_config('request.jwt.claims', cac, true); execute 'set local role authenticated';
    insert into public.profile_views(worker_id, viewer_id) values (wk, ca);
    execute 'reset role'; insert into _t14 values ('log ซ้ำ → 1 viewer=1 view','NO ERROR (dup!)',false);
  exception when others then execute 'reset role'; insert into _t14 values ('log ซ้ำ → 1 viewer=1 view','errored ✓ (dedup)',true); end;

  -- T3: clinic A สวมรอย viewer_id=B → RLS block
  begin
    perform set_config('request.jwt.claims', cac, true); execute 'set local role authenticated';
    insert into public.profile_views(worker_id, viewer_id) values (wk, cb);
    execute 'reset role'; insert into _t14 values ('สวมรอย viewer_id คนอื่น (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t14 values ('สวมรอย viewer_id คนอื่น (ต้อง fail)','errored ✓',true); end;

  -- T4: worker ดูตัวเอง (self-view) → RLS block (viewer <> worker)
  begin
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    insert into public.profile_views(worker_id, viewer_id) values (wk, wk);
    execute 'reset role'; insert into _t14 values ('self-view (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t14 values ('self-view (ต้อง fail)','errored ✓',true); end;

  -- T5: worker อ่านยอดตัวเอง → เห็น 1 (จาก A)
  begin
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    select count(*) into n from public.profile_views where worker_id=auth.uid(); execute 'reset role';
    insert into _t14 values ('worker อ่านยอดตัวเอง = 1', n::text, n=1);
  exception when others then execute 'reset role'; insert into _t14 values ('worker อ่านยอดตัวเอง','EXC:'||sqlerrm,false); end;

  -- T6: clinic B (ไม่ใช่เจ้าของ) อ่านยอดของ worker → 0 (privacy)
  begin
    perform set_config('request.jwt.claims', cbc, true); execute 'set local role authenticated';
    select count(*) into n from public.profile_views where worker_id=wk; execute 'reset role';
    insert into _t14 values ('คนอื่นอ่านยอด worker = 0 (privacy)', n::text, n=0);
  exception when others then execute 'reset role'; insert into _t14 values ('คนอื่นอ่านยอด worker','EXC:'||sqlerrm,false); end;

  delete from auth.users where id in (wk,ca,cb);
end $$;
select * from _t14;
