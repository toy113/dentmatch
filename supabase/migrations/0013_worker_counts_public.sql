-- DentMatch — 0013 · public aggregate นับบุคลากร (guest teaser ใช้เลขจริง)
-- รันหลัง 0001-0012
-- ปัญหา: wp_sel (0001) = `for select to authenticated` → guest(anon) อ่าน/นับ worker_profiles ไม่ได้ (ได้ 0)
--   teaser ฝั่ง guest เลย hardcode เลข mock (94/40/35/19) ไว้
-- โมเดล (decision): ไม่เปิด RLS ให้ anon อ่าน worker_profiles (จะหลุดข้อมูลรายคน = ผิด privacy model)
--   แทนที่ด้วยฟังก์ชัน aggregate (security definer) ที่คืน "เฉพาะจำนวนนับ" ตามตำแหน่ง — ไม่มีข้อมูลรายคนหลุด
--   grant execute ให้ anon+authenticated → frontend เรียกผ่าน rpc('worker_counts') มาเติม teaser/stats

-- ════════ A) ฟังก์ชัน aggregate (security definer · bypass RLS โดยตั้งใจ — คืนแค่ count) ════════
create or replace function public.worker_counts()
returns table(total int, dentist int, assistant int, counter int)
language sql
security definer
set search_path = public
stable
as $$
  select count(*)::int,
         count(*) filter (where position = 'dentist')::int,
         count(*) filter (where position = 'assistant')::int,
         count(*) filter (where position = 'counter')::int
  from public.worker_profiles;
$$;

comment on function public.worker_counts() is
  'DentMatch: นับบุคลากรในระบบแยกตามตำแหน่ง (total/dentist/assistant/counter). คืนแค่ตัวเลข — ไม่เปิดข้อมูลรายคน. ใช้โดย guest teaser + stats band ผ่าน rpc.';

-- เปิดให้ทั้ง guest(anon) และ authenticated เรียกได้ (เปิดแค่ตัวเลขรวม ปลอดภัย)
revoke all on function public.worker_counts() from public;
grant execute on function public.worker_counts() to anon, authenticated;

-- ════════ B) SELF-TEST (_t13 : pass ต้อง true ทั้งหมด) ════════
drop table if exists _t13;
create temp table _t13(test text, result text, pass boolean);
do $$
declare
  w1 uuid := '00000000-0000-0000-0000-0000000c1301';   -- throwaway dentist
  w2 uuid := '00000000-0000-0000-0000-0000000c1302';   -- throwaway assistant
  b_tot int; b_den int; b_asi int; b_cnt int;          -- baseline (ก่อน insert)
  a_tot int; a_den int; a_asi int; a_cnt int;          -- after insert
  anon_ok boolean := false;
begin
  -- teardown เผื่อรอบก่อนค้าง
  delete from auth.users where id in (w1, w2);

  -- baseline (owner context)
  select total, dentist, assistant, counter into b_tot, b_den, b_asi, b_cnt from public.worker_counts();

  -- seed: 1 dentist + 1 assistant (anon_id='pending' → trg_gen_anon เซ็ตจริงให้)
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data) values
    ('00000000-0000-0000-0000-000000000000',w1,'authenticated','authenticated','wc.dentist@dentmatch.local',  now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
    ('00000000-0000-0000-0000-000000000000',w2,'authenticated','authenticated','wc.assistant@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (w1,'worker'),(w2,'worker') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values
    (w1,'pending','dentist','กรุงเทพมหานคร'),
    (w2,'pending','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  select total, dentist, assistant, counter into a_tot, a_den, a_asi, a_cnt from public.worker_counts();

  -- T1: total เพิ่มขึ้น 2
  insert into _t13 values ('total เพิ่มขึ้น 2 หลัง insert 2 คน', format('%s → %s', b_tot, a_tot), a_tot = b_tot + 2);
  -- T2: dentist เพิ่มขึ้น 1
  insert into _t13 values ('dentist เพิ่มขึ้น 1', format('%s → %s', b_den, a_den), a_den = b_den + 1);
  -- T3: assistant เพิ่มขึ้น 1
  insert into _t13 values ('assistant เพิ่มขึ้น 1', format('%s → %s', b_asi, a_asi), a_asi = b_asi + 1);
  -- T4: counter ไม่เปลี่ยน
  insert into _t13 values ('counter ไม่เปลี่ยน', format('%s → %s', b_cnt, a_cnt), a_cnt = b_cnt);
  -- T5: total = dentist + assistant + counter (position เป็น enum NOT NULL → ผลรวมเป๊ะ)
  insert into _t13 values ('total = dentist+assistant+counter', format('%s = %s+%s+%s', a_tot, a_den, a_asi, a_cnt), a_tot = a_den + a_asi + a_cnt);

  -- T6: guest(anon) เรียกฟังก์ชันได้จริง (ไม่ raise — นี่คือหัวใจของ 0013)
  begin
    execute 'set local role anon';
    perform public.worker_counts();
    execute 'reset role';
    anon_ok := true;
  exception when others then execute 'reset role'; anon_ok := false; end;
  insert into _t13 values ('anon เรียก worker_counts() ได้', case when anon_ok then 'ok ✓' else 'EXC' end, anon_ok);

  -- cleanup throwaway
  delete from auth.users where id in (w1, w2);
end $$;
select * from _t13;
