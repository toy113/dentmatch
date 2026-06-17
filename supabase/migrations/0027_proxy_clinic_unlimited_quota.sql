-- DentMatch — 0027 · ปลดล็อก quota ของ proxy clinic "นำเข้าจาก LINE"
-- รันหลัง 0026 (ที่สร้าง proxy clinic)
-- เหตุผล: proxy clinic โพสต์แทนหลายคลินิกพร้อมกัน — ถ้าติด quota 7 จะบล็อกหลังนำเข้า 7 งาน

update public.clinics
  set open_job_quota = null   -- null = unlimited (ดู 0024_open_job_quota.sql)
  where id = public.dm_proxy_clinic_id();

-- ตรวจสอบ
do $$
declare q int;
begin
  select open_job_quota into q from public.clinics where id = public.dm_proxy_clinic_id();
  if q is not null then
    raise exception 'proxy clinic ยังติด quota = % (ต้องเป็น null)', q;
  end if;
  raise notice 'proxy clinic quota = null (unlimited) ✓';
end $$;
