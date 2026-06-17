-- DentMatch — แก้วันที่ปี พ.ศ. → ค.ศ. ในข้อมูลที่นำเข้าจาก LINE
-- รันใน Supabase Dashboard → SQL Editor (service_role → bypass RLS)
--
-- ที่มาของบั๊ก: parse-job-draft (AI) เคยสกัดวันที่จากโพสต์ที่เขียนปีไทย เช่น
-- "สิงหาคม2569" แล้วเก็บเป็น '2569-08-01' ตรง ๆ (ควรเป็น '2026-08-01')
-- ผลคือ date filter ฝั่ง worker หาไม่เจอ เพราะตัวเลือกวันให้ค่าปี ค.ศ.
--
-- กฎแปลง: ปี >= 2500 = พ.ศ. → ลบ 543  (2569 → 2026)
-- แก้ทั้ง jobs.work_dates / jobs.work_date และ job_drafts.parsed.work_dates
-- ปลอดภัยรันซ้ำได้ (idempotent: ปี ค.ศ. < 2500 จะไม่ถูกแตะ)

-- ============================================================
-- 0) ตรวจก่อนแก้ — ดูแถวที่ยังมีปี พ.ศ. (ปี >= 2500)
-- ============================================================
select id, title, work_dates, work_date
from jobs
where exists (
  select 1 from unnest(coalesce(work_dates, array[]::text[])) d
  where substring(d from 1 for 4)::int >= 2500
)
   or (work_date is not null and substring(work_date::text from 1 for 4)::int >= 2500);

select id, sender_name, parsed->'work_dates' as work_dates
from job_drafts
where jsonb_typeof(parsed->'work_dates') = 'array'
  and exists (
    select 1 from jsonb_array_elements_text(parsed->'work_dates') d
    where substring(d from 1 for 4)::int >= 2500
  );

-- ============================================================
-- 1) แก้ jobs.work_dates (text[]) — ลบ 543 จากปีที่ >= 2500
-- ============================================================
update jobs
set work_dates = (
  select array_agg(
    case when substring(d from 1 for 4)::int >= 2500
         then (substring(d from 1 for 4)::int - 543)::text || substring(d from 5)
         else d end
    order by ord
  )
  from unnest(work_dates) with ordinality as t(d, ord)
)
where exists (
  select 1 from unnest(coalesce(work_dates, array[]::text[])) d
  where substring(d from 1 for 4)::int >= 2500
);

-- ============================================================
-- 2) แก้ jobs.work_date (วันเดียว / backward-compat)
-- ============================================================
update jobs
set work_date = ((substring(work_date::text from 1 for 4)::int - 543)::text
                 || substring(work_date::text from 5))::date
where work_date is not null
  and substring(work_date::text from 1 for 4)::int >= 2500;

-- ============================================================
-- 3) แก้ job_drafts.parsed.work_dates (jsonb array) — เผื่อเปิดฟอร์ม publish ซ้ำ
-- ============================================================
update job_drafts
set parsed = jsonb_set(
  parsed,
  '{work_dates}',
  (
    select jsonb_agg(
      case when substring(d from 1 for 4)::int >= 2500
           then to_jsonb((substring(d from 1 for 4)::int - 543)::text || substring(d from 5))
           else to_jsonb(d) end
    )
    from jsonb_array_elements_text(parsed->'work_dates') d
  )
)
where jsonb_typeof(parsed->'work_dates') = 'array'
  and exists (
    select 1 from jsonb_array_elements_text(parsed->'work_dates') d
    where substring(d from 1 for 4)::int >= 2500
  );

-- ============================================================
-- 4) ตรวจหลังแก้ — ควรได้ 0 แถวทั้งสอง query ในข้อ 0
-- ============================================================
