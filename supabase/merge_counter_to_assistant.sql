-- DentMatch — ยุบตำแหน่ง "เคาน์เตอร์" → รวมเข้า "ผู้ช่วยฯ" (counter → assistant)
-- รันใน Supabase Dashboard → SQL Editor (service_role → bypass RLS)
--
-- บริบท: เอาตำแหน่ง counter ออกจาก UI ทุกจุดแล้ว (เหลือ ทันตแพทย์ / ผู้ช่วยฯ)
-- สคริปต์นี้ย้ายข้อมูลเดิมที่ position='counter' ทั้งฝั่งบุคลากรและงาน → 'assistant'
-- ปลอดภัยรันซ้ำได้ (idempotent: ไม่มี counter เหลือ = อัปเดต 0 แถว)
--
-- หมายเหตุ trigger enforce_position_lock: อนุญาต assistant↔counter อยู่แล้ว → UPDATE นี้ผ่าน
-- enum/constraint ของ position ปล่อยไว้ได้ (ค่า 'counter' ยังคงอยู่ในชนิดข้อมูลแต่ไม่มีใครใช้)

-- ============================================================
-- 0) ตรวจก่อนแก้ — นับแถวที่ยังเป็น counter
-- ============================================================
select 'worker_profiles' as tbl, count(*) from worker_profiles where position = 'counter'
union all
select 'jobs', count(*) from jobs where position = 'counter';

-- ============================================================
-- 1) บุคลากร: counter → assistant
-- ============================================================
update worker_profiles set position = 'assistant' where position = 'counter';

-- ============================================================
-- 2) งาน: counter → assistant
-- ============================================================
update jobs set position = 'assistant' where position = 'counter';

-- ============================================================
-- 3) ตรวจหลังแก้ — ควรได้ 0 ทั้งสองแถว
-- ============================================================
select 'worker_profiles' as tbl, count(*) from worker_profiles where position = 'counter'
union all
select 'jobs', count(*) from jobs where position = 'counter';
