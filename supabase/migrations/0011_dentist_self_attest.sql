-- DentMatch — 0011 · เปิดรับทันตแพทย์แบบ self-attestation (ไม่ verify ใบประกอบ)
-- รันหลัง 0001-0010
-- โมเดล (decision): DentMatch = สื่อกลาง · รับ dentist เลย (license_verified=false เสมอ)
--   · เก็บ license_no (worker_license = audit trail) · attestation + disclosure ฝั่ง UI · clause ใน terms
--   · ไม่มี badge verified · คลินิกมีหน้าที่ตรวจสอบใบประกอบเอง
-- (แทน C4g upload+admin-verify · verify จริงทำภายหลังได้ถ้าจะทำ ผ่าน service_role)

-- ════════ A) เปิด INSERT เป็น dentist (แก้ gate 0002) — ยังบังคับ server fields ════════
-- เดิม (0002): สมัคร dentist ตรง ๆ ถูกบล็อก · ตอนนี้: อนุญาต แต่ license_verified=false เสมอ
-- (badge เซ็ตได้ทางเดียวผ่าน worker_license.verified -> trg_sync_license โดย admin/service_role)
create or replace function public.enforce_position_lock_insert() returns trigger
language plpgsql as $$
begin
  -- server fields: client กำหนดเองไม่ได้ (กันปลอม badge/trust ตอน insert)
  new.license_verified := false;
  new.trust_score      := 0;
  new.no_show_count    := 0;
  new.seeded           := coalesce(new.seeded, false);   -- admin seed ผ่าน service_role ทีหลังได้
  -- (ตัด gate ที่ raise เมื่อ position='dentist' ออก — รับ self-attestation)
  return new;
end; $$;
-- trigger trg_pos_gate_insert (0002) ยังผูกกับฟังก์ชันนี้ → ไม่ต้องสร้างใหม่

-- ════════ B) HARDEN worker_license INSERT — กัน client เซ็ต verified=true ตอน insert ════════
-- เดิม (0001) revoke แค่ UPDATE → INSERT ลอด → client insert verified=true -> trg_sync_license เด้ง badge = ช่องโหว่
-- เปิด INSERT เฉพาะ worker_id/license_no/doc_path ; verified/verified_at/verified_by = service_role เท่านั้น
revoke insert on public.worker_license from authenticated;
grant  insert (worker_id, license_no, doc_path) on public.worker_license to authenticated;

-- ============================================================
-- TEST (_t11 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t11;
create temp table _t11(test text, result text, pass boolean);
do $$
declare uid uuid := '00000000-0000-0000-0000-0000000000de';
        dc  text := json_build_object('sub','00000000-0000-0000-0000-0000000000de','role','authenticated')::text;
        pos text; lv boolean; lic text; vrf boolean;
begin
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated','dentist.attest@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (uid,'worker') on conflict (id) do nothing;

  -- T1: สมัครเป็น dentist ได้แล้ว (insert ผ่าน) + license_verified ถูกบังคับ false (แม้ client แอบใส่ true)
  begin
    perform set_config('request.jwt.claims', dc, true); execute 'set local role authenticated';
    insert into public.worker_profiles(id,anon_id,position,province,license_verified)
      values (uid,'pending','dentist','กรุงเทพมหานคร',true);
    execute 'reset role';
    select position, license_verified into pos, lv from public.worker_profiles where id=uid;
    insert into _t11 values ('สมัคร dentist ได้ + license_verified=false', 'pos='||pos||' lv='||lv, pos='dentist' and lv=false);
  exception when others then execute 'reset role'; insert into _t11 values ('สมัคร dentist','EXC:'||sqlerrm,false); end;

  -- T2: client insert worker_license พร้อม verified=true → ต้อง ERROR (ไม่มีสิทธิ์ column verified) · ทำก่อน insert จริง (ยังไม่มี row)
  begin
    perform set_config('request.jwt.claims', dc, true); execute 'set local role authenticated';
    insert into public.worker_license(worker_id, license_no, verified) values (uid, 'x', true);
    execute 'reset role'; insert into _t11 values ('client insert verified=true (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t11 values ('client insert verified=true (ต้อง fail)','errored ✓',true); end;

  -- T3: owner insert worker_license(license_no) ได้ + verified default false
  begin
    perform set_config('request.jwt.claims', dc, true); execute 'set local role authenticated';
    insert into public.worker_license(worker_id, license_no) values (uid, 'ท.12345');
    execute 'reset role';
    select license_no, verified into lic, vrf from public.worker_license where worker_id=uid;
    insert into _t11 values ('owner insert license_no ได้ + verified=false', 'no='||coalesce(lic,'∅')||' vrf='||vrf, lic='ท.12345' and vrf=false);
  exception when others then execute 'reset role'; insert into _t11 values ('owner insert license_no','EXC:'||sqlerrm,false); end;

  -- T4: license_verified ของ worker ยังเป็น false (badge ไม่ขึ้นเองจากการสมัคร)
  select license_verified into lv from public.worker_profiles where id=uid;
  insert into _t11 values ('สมัครแล้ว license_verified ยัง false (ไม่มี badge auto)', 'lv='||lv, lv=false);

  delete from auth.users where id = uid;
end $$;
select * from _t11;
