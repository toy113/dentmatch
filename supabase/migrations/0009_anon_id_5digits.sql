-- DentMatch — 0009 · anon_id 5 หลัก (เดิม 6)
-- รันหลัง 0001-0008
-- frontend อ่าน anon_id จาก DB อยู่แล้ว → ไม่ต้องแก้ frontend

-- gen สำหรับ worker ใหม่ : 5 หลัก
create or replace function public.gen_anon_id() returns trigger
language plpgsql security definer set search_path = public as $$
declare candidate text;
begin
  loop
    candidate := lpad((floor(random()*100000))::int::text, 5, '0');   -- 00000–99999
    exit when not exists (select 1 from public.worker_profiles where anon_id = candidate);
  end loop;
  new.anon_id := candidate;
  new.position_locked := (new.position = 'dentist');
  return new;
end; $$;

-- backfill : worker เดิมที่ anon_id ไม่ใช่ 5 หลัก → สร้างใหม่ 5 หลัก unique
do $$
declare r record; cand text;
begin
  for r in select id from public.worker_profiles where anon_id !~ '^[0-9]{5}$' loop
    loop
      cand := lpad((floor(random()*100000))::int::text, 5, '0');
      exit when not exists (select 1 from public.worker_profiles where anon_id = cand);
    end loop;
    update public.worker_profiles set anon_id = cand where id = r.id;
  end loop;
end $$;

-- ============================================================
-- TEST (_t9 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t9;
create temp table _t9(test text, result text, pass boolean);
do $$
declare uid uuid := '00000000-0000-0000-0000-0000000000f7'; aid text; n int;
begin
  -- worker ใหม่ → trigger gen anon_id 5 หลัก (insert ใส่ 'pending' แต่ trigger override)
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated','anon5.test@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}') on conflict (id) do nothing;
  insert into public.profiles(id,role) values (uid,'worker') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (uid,'pending','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;
  select anon_id into aid from public.worker_profiles where id=uid;
  insert into _t9 values ('worker ใหม่ → anon_id 5 หลัก', 'anon='||coalesce(aid,'∅'), aid ~ '^[0-9]{5}$');

  -- backfill: ทุก worker เป็น 5 หลักหมด
  select count(*) into n from public.worker_profiles where anon_id !~ '^[0-9]{5}$';
  insert into _t9 values ('ทุก worker anon_id = 5 หลัก (backfill)', n::text||' ตัวที่ยังไม่ใช่ 5 หลัก', n=0);

  delete from auth.users where id = uid;
end $$;
select * from _t9;
