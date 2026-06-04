-- DentMatch — 0003 · worker display fields (ให้การ์ด .wcard render ของจริงครบ 100%)
-- รันหลัง 0001, 0002
-- เพิ่ม: experience_years (ฟอร์มสมัครเก็บอยู่แล้ว), available_days int[] (1=จันทร์ … 7=อาทิตย์ → ตรง .days .d)

alter table public.worker_profiles
  add column if not exists experience_years int,
  add column if not exists available_days    int[] not null default '{}';   -- 1=จ 2=อ 3=พ 4=พฤ 5=ศ 6=ส 7=อา

-- column GRANT (ADDITIVE) : worker แก้ 2 คอลัมน์นี้เองได้ — GRANT เพิ่มเฉพาะ 2 ตัว ไม่แตะของเดิม
-- (trust_score/anon_id/position_locked/member_since/license_verified/seeded/no_show_count ยัง revoke อยู่ตาม 0001)
grant update (experience_years, available_days) on public.worker_profiles to authenticated;

-- ============================================================
-- QUICK TEST (ลบ test user เอง) — ดู Notices: ต้อง TEST 1 PASS + TEST 2 PASS
-- ============================================================
do $$
declare uid uuid := '00000000-0000-0000-0000-0000000000e1';
        claims text := json_build_object('sub','00000000-0000-0000-0000-0000000000e1','role','authenticated')::text;
begin
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated','disp.test@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (uid,'worker') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (uid,'x','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- TEST 1: worker แก้ experience_years + available_days = ต้องได้
  begin
    perform set_config('request.jwt.claims', claims, true);
    execute 'set local role authenticated';
    update public.worker_profiles set experience_years=5, available_days='{6,7}' where id=auth.uid();
    execute 'reset role';
    raise notice 'TEST 1 PASS: worker update experience_years/available_days สำเร็จ';
  exception when others then execute 'reset role';
    raise notice 'TEST 1 FAIL: %', sqlerrm; end;

  -- TEST 2: trust_score ต้องยังถูกบล็อก (ยืนยันไม่เผลอ re-grant)
  begin
    perform set_config('request.jwt.claims', claims, true);
    execute 'set local role authenticated';
    update public.worker_profiles set trust_score=999 where id=auth.uid();
    execute 'reset role';
    raise notice 'TEST 2 FAIL: trust_score update ผ่าน (ไม่ควร — re-grant หลุด!)';
  exception when others then execute 'reset role';
    raise notice 'TEST 2 PASS: trust_score ยังถูกบล็อก (%)', sqlerrm; end;

  delete from auth.users where id = uid;
end $$;
