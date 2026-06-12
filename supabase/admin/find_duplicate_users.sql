-- DentMatch — admin · หาคู่บัญชีที่ "น่าจะเป็นคนเดียวกัน" (ดูก่อนลบด้วยมือ)
-- รันใน Supabase SQL Editor (service_role) — อ่านอย่างเดียว ไม่แก้ข้อมูล
-- เทียบ 3 มิติ: email / ชื่อ / เบอร์ — แสดงคู่ + เหตุผลที่แมตช์ + วันสมัคร (เก่า→ใหม่)
--
-- หมายเหตุ:
--   • LINE ใช้ synthetic email 'line_<uid>@line.dentmatch.local' → ไม่นับเป็น email จริงตอนเทียบ
--   • คู่ที่ login_kind ต่างกัน (email ↔ line) = เป้าหมายหลัก (คนเดิมสมัครซ้ำคนละช่องทาง)
--   • ลบ test account ที่ซ้ำด้วยมือ: ลบที่ auth.users (id) → cascade ลบ profiles/clinics/worker_* ให้เอง

with u as (
  select
    p.id,
    p.role,
    p.created_at,
    au.email as auth_email,
    case when au.email like 'line\_%@line.dentmatch.local' then 'line' else 'email' end as login_kind,
    -- ชื่อแสดง: คลินิก=name ; worker=ชื่อ+นามสกุล
    nullif(trim(lower(coalesce(c.name, coalesce(wp.first_name,'')||' '||coalesce(wp.last_name,'')))),'') as name_norm,
    -- email จริงสำหรับเทียบ: auth email (ถ้าไม่ใช่ line) + worker email
    nullif(lower(case when au.email like 'line\_%@line.dentmatch.local' then null else au.email end),'') as email_a,
    nullif(lower(wp.email),'') as email_b,
    -- เบอร์: เก็บเฉพาะตัวเลข
    nullif(regexp_replace(coalesce(c.phone, wp.phone, ''), '\D', '', 'g'), '') as phone_norm
  from public.profiles p
  join auth.users au              on au.id = p.id
  left join public.clinics c      on c.id = p.id
  left join public.worker_private wp on wp.worker_id = p.id
),
pairs as (
  select a.id as id_a, b.id as id_b,
         a.role role_a, b.role role_b,
         a.login_kind kind_a, b.login_kind kind_b,
         a.auth_email email_a_raw, b.auth_email email_b_raw,
         a.name_norm name_a, b.name_norm name_b,
         a.phone_norm phone_a, b.phone_norm phone_b,
         a.created_at created_a, b.created_at created_b,
         -- เหตุผลที่แมตช์
         (a.email_a is not null and a.email_a in (b.email_a, b.email_b))
         or (a.email_b is not null and a.email_b in (b.email_a, b.email_b)) as match_email,
         (a.name_norm is not null and a.name_norm = b.name_norm)            as match_name,
         (a.phone_norm is not null and a.phone_norm = b.phone_norm)         as match_phone
  from u a
  join u b on a.id < b.id   -- คู่ไม่ซ้ำ (a,b) เดียว
)
select
  -- เรียง: คู่ที่แมตช์หลายมิติ + ข้ามช่องทาง (email↔line) ขึ้นก่อน
  array_remove(array[
    case when match_email then 'email' end,
    case when match_name  then 'ชื่อ'  end,
    case when match_phone then 'เบอร์' end
  ], null) as matched_on,
  (kind_a <> kind_b) as cross_channel,
  least(created_a, created_b) as older_signup,
  greatest(created_a, created_b) as newer_signup,
  role_a, kind_a, email_a_raw, name_a, phone_a, id_a,
  role_b, kind_b, email_b_raw, name_b, phone_b, id_b
from pairs
where match_email or match_name or match_phone
order by (match_email::int + match_name::int + match_phone::int) desc,
         (kind_a <> kind_b) desc,
         older_signup;
