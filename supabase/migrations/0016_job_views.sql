-- DentMatch — 0016 · job_views (นับ "ยอดวิวงาน" จริง · unique viewer/job)
-- รันหลัง 0001-0015
-- โมเดล: worker(viewer) เปิดหน้ารายละเอียดงาน → log 1 แถวต่อ (job, viewer) · count = จำนวนคนดู (distinct, กันปั่นด้วย unique)
--   · โชว์ทั้ง "บอร์ดงานสาธารณะ" + "การ์ด manage ของคลินิก" → ยอดต้องอ่านแบบ public
--   · กันเผย viewer_id (ใครดู = privacy) → ยอด public อ่านผ่าน RPC job_views_count() (SECURITY DEFINER, คืนแค่ตัวเลข)
--   · raw rows: เจ้าของงาน/admin อ่านได้เท่านั้น · ไม่นับเจ้าของดูงานตัวเอง · ไม่แตะ protected fields

create table if not exists public.job_views (
  id         uuid primary key default gen_random_uuid(),
  job_id     uuid not null references public.jobs(id)     on delete cascade,
  viewer_id  uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (job_id, viewer_id)   -- 1 viewer = 1 view (index นี้ครอบ count by job_id ด้วย)
);

alter table public.job_views enable row level security;

-- INSERT: viewer log ในนามตัวเอง + ไม่นับเจ้าของงาน (self-view ของคลินิก)
drop policy if exists jv_ins on public.job_views;
create policy jv_ins on public.job_views for insert to authenticated
  with check (viewer_id = auth.uid() and viewer_id <> (select clinic_id from public.jobs where id = job_id));
-- SELECT raw: เจ้าของงานอ่านของตัวเอง (admin อ่านได้หมด) · ยอด public ใช้ RPC ไม่ใช่ raw
drop policy if exists jv_sel on public.job_views;
create policy jv_sel on public.job_views for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_views.job_id and j.clinic_id = auth.uid()) or public.is_admin());

revoke all on public.job_views from authenticated, anon;
grant select on public.job_views to authenticated;
grant insert (job_id, viewer_id) on public.job_views to authenticated;

-- RPC นับยอด public (คืนแค่ job_id + n · ไม่เผย viewer_id) — เรียกได้ทั้ง guest + worker + clinic
create or replace function public.job_views_count(ids uuid[])
returns table(job_id uuid, n bigint)
language sql security definer stable
set search_path = public
as $$
  select job_id, count(*)::bigint
  from public.job_views
  where job_id = any(ids)
  group by job_id;
$$;
revoke all on function public.job_views_count(uuid[]) from public;
grant execute on function public.job_views_count(uuid[]) to anon, authenticated;

-- ============================================================
-- TEST (_t16 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t16;
create temp table _t16(test text, result text, pass boolean);
do $$
declare
  ca uuid := '00000000-0000-0000-0000-0000000d1601';   -- clinic A (เจ้าของงาน)
  wk uuid := '00000000-0000-0000-0000-0000000d1602';   -- worker (viewer)
  cb uuid := '00000000-0000-0000-0000-0000000d1603';   -- clinic B (คนอื่น)
  jb uuid := 'ffff1601-1601-1601-1601-160116011601';   -- งานของ A
  cac text := json_build_object('sub','00000000-0000-0000-0000-0000000d1601','role','authenticated')::text;
  wkc text := json_build_object('sub','00000000-0000-0000-0000-0000000d1602','role','authenticated')::text;
  cbc text := json_build_object('sub','00000000-0000-0000-0000-0000000d1603','role','authenticated')::text;
  n int; cnt int;
begin
  delete from auth.users where id in (ca,wk,cb);
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',ca,'authenticated','authenticated','jv.clinicA@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',wk,'authenticated','authenticated','jv.worker@dentmatch.local', now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',cb,'authenticated','authenticated','jv.clinicB@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (ca,'clinic'),(wk,'worker'),(cb,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (ca,'คลินิก A jv','กรุงเทพมหานคร'),(cb,'คลินิก B jv','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (wk,'jv016','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.jobs(id,clinic_id,title,position,province) values (jb,ca,'งาน jv test','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: worker log วิว → OK
  begin
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    insert into public.job_views(job_id, viewer_id) values (jb, wk);
    execute 'reset role'; insert into _t16 values ('worker log วิว (insert)','ok ✓',true);
  exception when others then execute 'reset role'; insert into _t16 values ('worker log วิว (insert)','EXC:'||sqlerrm,false); end;

  -- T2: worker log ซ้ำ → unique violation = dedup
  begin
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    insert into public.job_views(job_id, viewer_id) values (jb, wk);
    execute 'reset role'; insert into _t16 values ('log ซ้ำ → 1 viewer=1 view','NO ERROR (dup!)',false);
  exception when others then execute 'reset role'; insert into _t16 values ('log ซ้ำ → 1 viewer=1 view','errored ✓ (dedup)',true); end;

  -- T3: worker สวมรอย viewer_id=B → RLS block
  begin
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    insert into public.job_views(job_id, viewer_id) values (jb, cb);
    execute 'reset role'; insert into _t16 values ('สวมรอย viewer_id คนอื่น (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t16 values ('สวมรอย viewer_id คนอื่น (ต้อง fail)','errored ✓',true); end;

  -- T4: เจ้าของงานดูงานตัวเอง (self-view) → RLS block
  begin
    perform set_config('request.jwt.claims', cac, true); execute 'set local role authenticated';
    insert into public.job_views(job_id, viewer_id) values (jb, ca);
    execute 'reset role'; insert into _t16 values ('เจ้าของดูงานตัวเอง (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t16 values ('เจ้าของดูงานตัวเอง (ต้อง fail)','errored ✓',true); end;

  -- T5: เจ้าของงานอ่าน raw rows → เห็น 1
  begin
    perform set_config('request.jwt.claims', cac, true); execute 'set local role authenticated';
    select count(*) into n from public.job_views where job_id=jb; execute 'reset role';
    insert into _t16 values ('เจ้าของอ่าน raw = 1', n::text, n=1);
  exception when others then execute 'reset role'; insert into _t16 values ('เจ้าของอ่าน raw','EXC:'||sqlerrm,false); end;

  -- T6: คลินิกอื่นอ่าน raw rows → 0 (privacy: ไม่เห็นว่าใครดู)
  begin
    perform set_config('request.jwt.claims', cbc, true); execute 'set local role authenticated';
    select count(*) into n from public.job_views where job_id=jb; execute 'reset role';
    insert into _t16 values ('คลินิกอื่นอ่าน raw = 0 (privacy)', n::text, n=0);
  exception when others then execute 'reset role'; insert into _t16 values ('คลินิกอื่นอ่าน raw','EXC:'||sqlerrm,false); end;

  -- T7: guest (anon) เรียก RPC นับยอด → ได้ n=1 (public count ใช้บนบอร์ดได้)
  begin
    execute 'set local role anon';
    select jvc.n into cnt from public.job_views_count(array[jb]) jvc where jvc.job_id=jb; execute 'reset role';
    insert into _t16 values ('anon เรียก job_views_count = 1 (public)', coalesce(cnt::text,'∅'), cnt=1);
  exception when others then execute 'reset role'; insert into _t16 values ('anon เรียก job_views_count','EXC:'||sqlerrm,false); end;

  delete from auth.users where id in (ca,wk,cb);
end $$;
select * from _t16;
