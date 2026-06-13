-- DentMatch — 0024 · จำกัดจำนวน "งานที่เปิดอยู่พร้อมกัน" ต่อคลินิก (กัน spam โพสต์งาน)
-- รันหลัง 0001-0023
-- แนวทาง A: นับเฉพาะงานที่ is_open=true และยังไม่หมดอายุ (expires_at > now) ถ้าครบโควต้า → ห้าม INSERT
-- free tier = 7 งาน ; null = ไม่จำกัด (เผื่อ paid tier / admin ปลดล็อกรายคลินิก ภายหลัง)
-- บังคับที่ DB (trigger) → client bypass ไม่ได้

-- ════════ A) คอลัมน์โควต้า (default 7 · null = unlimited) ════════
alter table public.clinics
  add column if not exists open_job_quota int default 7;

-- ════════ B) trigger before insert on jobs ════════
create or replace function public.enforce_open_job_quota()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare q int; c int;
begin
  if NEW.is_open is not true then return NEW; end if;            -- งานปิดมาแต่แรก ไม่นับ
  select open_job_quota into q from public.clinics where id = NEW.clinic_id;
  if q is null then return NEW; end if;                          -- unlimited
  select count(*) into c from public.jobs
    where clinic_id = NEW.clinic_id
      and is_open = true
      and (expires_at is null or expires_at > now());
  if c >= q then
    raise exception 'เปิดงานพร้อมกันได้สูงสุด % งาน — ปิดงานเก่าก่อนจึงจะโพสต์เพิ่มได้', q
      using errcode = 'P0001';
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_open_job_quota on public.jobs;
create trigger trg_open_job_quota
  before insert on public.jobs
  for each row execute function public.enforce_open_job_quota();

-- ============================================================
-- TEST (_t24 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t24;
create temp table _t24(test text, result text, pass boolean);
do $$
declare cl uuid := '00000000-0000-0000-0000-0000000024c1';
        clc text := json_build_object('sub','00000000-0000-0000-0000-0000000024c1','role','authenticated')::text;
        i int; ok boolean; n int;
begin
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',cl,'authenticated','authenticated','quota.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิกทดสอบโควต้า','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: default โควต้า = 7
  select open_job_quota into i from public.clinics where id=cl;
  insert into _t24 values ('default open_job_quota = 7', coalesce(i::text,'NULL'), i=7);

  -- โพสต์ 7 งาน (ในฐานะคลินิก) → ควรผ่านทั้งหมด
  perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
  ok := true;
  begin
    for n in 1..7 loop
      insert into public.jobs(clinic_id,title,position,province) values (cl,'งาน '||n,'assistant','กรุงเทพมหานคร');
    end loop;
  exception when others then ok := false; end;
  execute 'reset role';
  select count(*) into i from public.jobs where clinic_id=cl and is_open=true;
  insert into _t24 values ('โพสต์ 7 งานแรกผ่าน', 'open='||i||' ok='||ok, ok and i=7);

  -- T2: งานที่ 8 → ต้อง ERROR
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province) values (cl,'งานที่ 8','assistant','กรุงเทพมหานคร');
    execute 'reset role';
    insert into _t24 values ('งานที่ 8 (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t24 values ('งานที่ 8 (ต้อง fail)','errored ✓',true); end;

  -- T3: ปิดงาน 1 งาน → โพสต์ใหม่ได้อีก 1
  update public.jobs set is_open=false where id=(select id from public.jobs where clinic_id=cl and is_open=true limit 1);
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province) values (cl,'งานหลังปิดเก่า','assistant','กรุงเทพมหานคร');
    get diagnostics i = row_count; execute 'reset role';
    insert into _t24 values ('ปิดงานเก่า 1 → โพสต์ใหม่ได้', i::text||' row', i=1);
  exception when others then execute 'reset role'; insert into _t24 values ('ปิดงานเก่า → โพสต์ใหม่','EXC:'||sqlerrm,false); end;

  -- T4: ตั้ง quota=null (unlimited) → โพสต์เกินได้
  update public.clinics set open_job_quota=null where id=cl;
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    insert into public.jobs(clinic_id,title,position,province) values (cl,'งาน unlimited','assistant','กรุงเทพมหานคร');
    get diagnostics i = row_count; execute 'reset role';
    insert into _t24 values ('quota=null (unlimited) → โพสต์เกินได้', i::text||' row', i=1);
  exception when others then execute 'reset role'; insert into _t24 values ('quota=null unlimited','EXC:'||sqlerrm,false); end;

  delete from auth.users where id = cl;   -- cascade ลบ profiles/clinics/jobs ที่ seed
end $$;
select * from _t24;
