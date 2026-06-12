-- DentMatch — 0024 · helper lookup: หา auth user จาก email (กันบัญชีซ้ำตอนสมัครด้วย LINE)
-- ใช้โดย Edge Function line-auth (service_role เท่านั้น) — PostgREST/anon/authenticated เข้าไม่ได้
-- เหตุผล: edge fn เข้าถึง schema public ผ่าน RPC ได้ แต่ query auth.users ตรง ๆ ไม่ได้

create or replace function public.find_auth_user_by_email(p_email text)
returns table(id uuid, provider text)
language sql
security definer
set search_path = public, auth
as $$
  select u.id,
         coalesce(u.raw_app_meta_data->>'provider', u.raw_user_meta_data->>'provider') as provider
  from auth.users u
  where lower(u.email) = lower(p_email)
  limit 1;
$$;

-- เปิดสิทธิ์เฉพาะ service_role (edge fn) — ปิดสำหรับทุก role อื่น
revoke all on function public.find_auth_user_by_email(text) from public, anon, authenticated;
grant execute on function public.find_auth_user_by_email(text) to service_role;
