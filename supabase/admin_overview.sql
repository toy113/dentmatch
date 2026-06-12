-- DentMatch — Admin Overview Queries
-- รันใน Supabase Dashboard → SQL Editor (รันเป็น service_role → bypass RLS, เห็นทุกแถว)
-- เน้น "ตัวเลขภาพรวม" สำหรับช่วง Soft Opening
-- แต่ละบล็อกรันแยกได้ (ไฮไลต์แล้วกด Run) หรือบันทึกเป็น Saved Query ทีละอัน

-- ============================================================
-- 1) สรุปรวมทั้งระบบ (one-shot dashboard) — ★ รันอันนี้อันเดียวเห็นภาพรวมครบในแถวเดียว
--    (ไฮไลต์ตั้งแต่ select ถึง ; แล้วกด Run / Ctrl+Enter)
-- ============================================================
select
  -- สมาชิก
  (select count(*) from profiles where role='worker')                       as workers,
  (select count(*) from profiles where role='clinic')                       as clinics,
  (select count(*) from worker_profiles where available)                    as workers_available,
  (select count(*) from worker_profiles where license_verified)             as workers_verified,
  -- งาน
  (select count(*) from jobs)                                               as jobs_total,
  (select count(*) from jobs where is_open)                                 as jobs_open,
  -- คำเชิญ (funnel)
  (select count(*) from invites)                                            as invites_total,
  (select count(*) from invites where read_at is not null)                  as invites_read,
  (select count(*) from invites where status='accepted')                    as invites_accepted,
  (select round(100.0*count(*) filter (where read_at is not null)
        /nullif(count(*),0),1) from invites)                                as open_rate_pct,
  (select round(100.0*count(*) filter (where status='accepted')
        /nullif(count(*),0),1) from invites)                                as accept_rate_pct,
  -- conversion จริง ★ ตัวชี้วัดหลัก (เกิดการจับคู่/แลกข้อมูลติดต่อ)
  (select count(*) from add_line_events)                                    as contacts_exchanged,
  -- งานที่บันทึก
  (select count(*) from work_logs where status='confirmed')                 as worklogs_confirmed,
  (select count(*) from work_logs where status='disputed')                  as worklogs_disputed,
  -- คำขอค้างรออนุมัติ
  (select count(*) from deletion_requests where status='requested')         as pending_deletions,
  (select count(*) from role_change_requests where status='pending')        as pending_role_changes;

-- ============================================================
-- 2) สมาชิกใหม่ต่อวัน (30 วันล่าสุด) — ดูเทรนด์การเติบโต
-- ============================================================
select
  date_trunc('day', created_at)::date          as day,
  count(*) filter (where role='worker')         as new_workers,
  count(*) filter (where role='clinic')         as new_clinics,
  count(*)                                       as new_total
from profiles
where created_at >= now() - interval '30 days'
group by 1 order by 1 desc;

-- ============================================================
-- 3) Funnel คำเชิญ → อ่าน → ตอบรับ → แลกข้อมูลติดต่อ
-- ============================================================
select
  count(*)                                                          as sent,
  count(*) filter (where read_at is not null)                       as opened,
  count(*) filter (where status='accepted')                         as accepted,
  count(*) filter (where status='declined')                         as declined,
  round(100.0 * count(*) filter (where read_at is not null)
        / nullif(count(*),0), 1)                                    as open_rate_pct,
  round(100.0 * count(*) filter (where status='accepted')
        / nullif(count(*),0), 1)                                    as accept_rate_pct
from invites;

-- จำนวนการแลกข้อมูลติดต่อ (add LINE) ต่อวัน — conversion จริง
select date_trunc('day', created_at)::date as day, count(*) as contacts
from add_line_events
where created_at >= now() - interval '30 days'
group by 1 order by 1 desc;

-- ============================================================
-- 4) ฝั่งงาน — โพสต์งานต่อวัน + แยกตำแหน่ง/จังหวัด
-- ============================================================
select date_trunc('day', created_at)::date as day, count(*) as jobs_posted
from jobs where created_at >= now() - interval '30 days'
group by 1 order by 1 desc;

select position, count(*) as jobs from jobs group by 1 order by 2 desc;
select province, count(*) as jobs from jobs group by 1 order by 2 desc limit 15;

-- ============================================================
-- 5) ฝั่ง worker — กระจายตามตำแหน่ง/จังหวัด + ยืนยันใบประกอบ
-- ============================================================
select position, count(*) as workers from worker_profiles group by 1 order by 2 desc;
select province, count(*) as workers from worker_profiles group by 1 order by 2 desc limit 15;
select
  count(*)                               as total,
  count(*) filter (where license_verified) as verified,
  count(*) filter (where no_show_count>0)  as has_no_show
from worker_profiles;

-- ============================================================
-- 6) คุณภาพ/ความน่าเชื่อถือ — งานมีข้อพิพาท + คู่ที่ทำงานกันบ่อย (ใช้ view ที่เตรียมไว้)
-- ============================================================
select * from v_disputed_logs;                 -- งานที่สองฝ่ายรายงานไม่ตรงกัน
select * from v_trust_abuse;                    -- คู่ clinic-worker ที่ยืนยัน >=5 ครั้ง (เฝ้าระวัง)

-- ============================================================
-- 7) คำขอที่รออนุมัติ (ถ้าจะดูควบคู่)
-- ============================================================
select count(*) filter (where status='requested') as pending_deletions from deletion_requests;
select count(*) filter (where status='pending')   as pending_role_changes from role_change_requests;
