-- DentMatch — 0017 · profile_views_count() RPC (ยอดวิวโปรไฟล์ public — โชว์บนการ์ดบุคลากรสาธารณะ)
-- รันหลัง 0014 (profile_views) + 0015 + 0016
-- profile_views.pv_sel ให้อ่านเฉพาะเจ้าของ (worker) → การ์ดบุคลากรสาธารณะ (คลินิก/guest) อ่านยอดไม่ได้
-- → RPC SECURITY DEFINER คืนแค่ (worker_id, n) ไม่เผย viewer_id (ใครดู = privacy) · เรียกได้ guest + clinic
-- (mirror job_views_count 0016 · ไม่สร้างตารางใหม่ · ไม่แตะ RLS เดิมของ profile_views)

create or replace function public.profile_views_count(ids uuid[])
returns table(worker_id uuid, n bigint)
language sql security definer stable
set search_path = public
as $$
  select worker_id, count(*)::bigint
  from public.profile_views
  where worker_id = any(ids)
  group by worker_id;
$$;
revoke all on function public.profile_views_count(uuid[]) from public;
grant execute on function public.profile_views_count(uuid[]) to anon, authenticated;

-- ============================================================
-- TEST (_t17 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t17;
create temp table _t17(test text, result text, pass boolean);
do $$
declare
  wk uuid := '00000000-0000-0000-0000-0000000d1701';   -- worker (ถูกดู)
  ca uuid := '00000000-0000-0000-0000-0000000d1702';   -- clinic (viewer)
  cnt int;
begin
  delete from auth.users where id in (wk,ca);
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',wk,'authenticated','authenticated','pvc.worker@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',ca,'authenticated','authenticated','pvc.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (wk,'worker'),(ca,'clinic') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (wk,'pvc017','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (ca,'คลินิก pvc','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.profile_views(worker_id,viewer_id) values (wk,ca) on conflict (worker_id,viewer_id) do nothing;   -- owner-context insert (bypass RLS)

  -- T1: guest (anon) เรียก RPC → ได้ n=1 (โชว์บนการ์ดบุคลากรได้ · ไม่เผย viewer)
  begin
    execute 'set local role anon';
    select pvc.n into cnt from public.profile_views_count(array[wk]) pvc where pvc.worker_id=wk; execute 'reset role';
    insert into _t17 values ('anon เรียก profile_views_count = 1 (public)', coalesce(cnt::text,'∅'), cnt=1);
  exception when others then execute 'reset role'; insert into _t17 values ('anon profile_views_count','EXC:'||sqlerrm,false); end;

  -- T2: กันเผย viewer — anon อ่าน raw profile_views ไม่ได้ (0 แถว "หรือ" permission denied = ผ่านทั้งคู่)
  begin
    execute 'set local role anon';
    select count(*) into cnt from public.profile_views where worker_id=wk; execute 'reset role';
    insert into _t17 values ('anon อ่าน raw profile_views ไม่ได้ (privacy)', 'เห็น '||cnt||' แถว', cnt=0);
  exception when others then execute 'reset role'; insert into _t17 values ('anon อ่าน raw profile_views ไม่ได้ (privacy)','permission denied ✓ (ปลอดภัยกว่า)',true); end;

  delete from auth.users where id in (wk,ca);
end $$;
select * from _t17;
