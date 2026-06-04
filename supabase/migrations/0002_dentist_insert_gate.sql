-- DentMatch — 0002 · dentist INSERT gate (ปิดช่องสมัครเป็นทันตแพทย์ตรง ๆ โดยไม่ verify)
-- รันบน Supabase project เดียวกัน หลัง 0001_dentmatch_init.sql
--
-- ปัญหา: §7.1 (0001) บล็อกแค่ UPDATE -> dentist ; INSERT ลอดได้
--        + column GRANT (0001) revoke แค่ UPDATE -> client ใส่ license_verified=true ตอน INSERT ได้
-- แก้: BEFORE INSERT trigger บน worker_profiles
--   (1) บังคับ server-field ให้เป็นค่าตั้งต้นเสมอ (license_verified=false, trust_score=0, no_show_count=0, seeded=false)
--       → ปิดช่อง client เซ็ตเอง ; badge เซ็ตได้ทางเดียวผ่าน worker_license.verify -> trg_sync_license
--   (2) เมื่อ license_verified ถูกบังคับเป็น false แล้ว position='dentist' ตอนสมัคร = บล็อก

create or replace function public.enforce_position_lock_insert() returns trigger
language plpgsql as $$
begin
  -- server fields: ห้าม client กำหนดตอน insert
  new.license_verified := false;
  new.trust_score      := 0;
  new.no_show_count    := 0;
  new.seeded           := coalesce(new.seeded, false);  -- (admin seed ผ่าน service_role จะ set ทีหลังได้)
  -- gate: สมัครเป็นทันตแพทย์ตรง ๆ ไม่ได้ (ต้อง verify ใบประกอบก่อน แล้วค่อย UPDATE -> dentist ตาม §7.1)
  if new.position = 'dentist' then
    raise exception 'สมัครเป็นทันตแพทย์โดยตรงไม่ได้ — สมัครเป็นผู้ช่วย/เคาน์เตอร์ แล้วยืนยันใบประกอบเพื่อขอเปลี่ยนเป็นทันตแพทย์ภายหลัง';
  end if;
  return new;
end; $$;

create trigger trg_pos_gate_insert before insert on public.worker_profiles
  for each row execute function public.enforce_position_lock_insert();

-- หมายเหตุ: trg_gen_anon (0001) ก็ BEFORE INSERT เช่นกัน — ทั้งคู่รันได้ ลำดับตามชื่อ trigger
--   trg_gen_anon (anon_id + position_locked) แล้ว trg_pos_gate_insert — ไม่ชนกัน
-- seeded: ปล่อยให้ service_role admin set ตอน concierge seed (decision 4) ผ่าน UPDATE/insert ด้วยสิทธิ์ owner

-- ============================================================
-- QUICK TEST (รันต่อท้าย, จะลบ test user เอง) — pass = trigger ทำงาน
-- ============================================================
do $$
declare uid uuid := '00000000-0000-0000-0000-0000000000d1'; ok boolean; lv boolean;
begin
  -- เตรียม user + profile (owner)
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated','gate.test@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (uid,'worker') on conflict (id) do nothing;

  -- (1) สมัครเป็น dentist = ต้อง error
  begin
    insert into public.worker_profiles(id,anon_id,position,province) values (uid,'x','dentist','กรุงเทพมหานคร');
    raise notice 'TEST 1 FAIL: dentist insert ผ่าน (ไม่ควรผ่าน)';
  exception when others then
    raise notice 'TEST 1 PASS: dentist insert ถูกบล็อก (%)', sqlerrm;
  end;

  -- (2) สมัครเป็น assistant + แอบใส่ license_verified=true = insert ผ่านแต่ badge ถูกบังคับ false
  insert into public.worker_profiles(id,anon_id,position,province,license_verified)
    values (uid,'x','assistant','กรุงเทพมหานคร',true);
  select license_verified into lv from public.worker_profiles where id=uid;
  if lv = false then raise notice 'TEST 2 PASS: license_verified ถูกบังคับเป็น false (กัน client ปลอม badge ตอน insert)';
  else raise notice 'TEST 2 FAIL: license_verified=% (ควร false)', lv; end if;

  -- cleanup
  delete from auth.users where id = uid;
end $$;
