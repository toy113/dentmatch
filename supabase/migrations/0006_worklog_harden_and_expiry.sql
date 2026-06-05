-- DentMatch — 0006 · work_logs hardening (RPC set_work_outcome · decision 3 §7.2) + jobs.expires_at
-- รันหลัง 0001-0005
-- decision 3: outcome นับเฉพาะ 2 ฝ่ายตรงกัน (confirmed) · ไม่ตรง=disputed · ห้าม auto นับ no_show ฝ่ายเดียว
-- spec บรรทัด 198: ใช้ RPC ให้แต่ละฝ่ายเซ็ตเฉพาะ outcome ตัวเอง (clinic→clinic_outcome, worker→worker_outcome)

-- ════════ A) jobs.expires_at (ต่ออายุ 60 วัน / สถานะหมดอายุ) ════════
alter table public.jobs
  add column if not exists expires_at timestamptz not null default (now() + interval '60 days');
-- "ต่ออายุ" = reset expires_at ; GRANT additive (RLS j_cud: เฉพาะ clinic เจ้าของ)
grant update (expires_at) on public.jobs to authenticated;

-- ════════ B) RPC set_work_outcome (security definer) ════════
-- แต่ละฝ่ายเซ็ตเฉพาะ outcome ของตัวเอง — กัน worker แตะ clinic_outcome (ปั่น trust)
create or replace function public.set_work_outcome(p_log uuid, p_outcome public.worklog_outcome)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare wl public.work_logs;
begin
  select * into wl from public.work_logs where id = p_log;
  if not found then raise exception 'work_log not found'; end if;
  if auth.uid() = wl.clinic_id then
    update public.work_logs set clinic_outcome = p_outcome where id = p_log;
  elsif auth.uid() = wl.worker_id then
    update public.work_logs set worker_outcome = p_outcome where id = p_log;
  else
    raise exception 'not a party to this work_log';
  end if;
end; $$;
revoke all on function public.set_work_outcome(uuid, public.worklog_outcome) from public;
grant execute on function public.set_work_outcome(uuid, public.worklog_outcome) to authenticated;

-- ════════ C) ปิด direct UPDATE work_logs → บังคับผ่าน RPC ════════
-- (กัน worker แก้ clinic_outcome / ฝ่ายเดียวปั่น · INSERT ยังเปิด: wl_ins gated clinic_id=auth.uid)
revoke update on public.work_logs from authenticated;

-- ============================================================
-- TEST (_t6 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t6;
create temp table _t6(test text, result text, pass boolean);
do $$
declare cl uuid := '00000000-0000-0000-0000-0000000000f3';   -- clinic
        wk uuid := '00000000-0000-0000-0000-0000000000f4';   -- worker
        clc text := json_build_object('sub','00000000-0000-0000-0000-0000000000f3','role','authenticated')::text;
        wkc text := json_build_object('sub','00000000-0000-0000-0000-0000000000f4','role','authenticated')::text;
        jid uuid := '44444444-4444-4444-4444-444444444444';
        lid uuid; ts int; st text; exp timestamptz; b boolean;
begin
  -- seed clinic + worker
  insert into auth.users (instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',cl,'authenticated','authenticated','wl.clinic@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}'),
           ('00000000-0000-0000-0000-000000000000',wk,'authenticated','authenticated','wl.worker@dentmatch.local',now(),now(),now(),'{"provider":"email","providers":["email"]}','{}')
    on conflict (id) do nothing;
  insert into public.profiles(id,role) values (cl,'clinic'),(wk,'worker') on conflict (id) do nothing;
  insert into public.clinics(id,name,province) values (cl,'คลินิก worklog','กรุงเทพมหานคร') on conflict (id) do nothing;
  insert into public.worker_profiles(id,anon_id,position,province) values (wk,'wltest','assistant','กรุงเทพมหานคร') on conflict (id) do nothing;   -- assistant: เลี่ยง dentist INSERT gate (0002) · trust/worklog ไม่ขึ้นกับตำแหน่ง
  insert into public.jobs(id,clinic_id,title,position,province) values (jid,cl,'งาน worklog','dentist','กรุงเทพมหานคร') on conflict (id) do nothing;

  -- T1: expires_at default ≈ now()+60d (ไม่ null, อยู่ในช่วง 59-61 วัน)
  select expires_at into exp from public.jobs where id=jid;
  insert into _t6 values ('jobs.expires_at default ~now()+60d', coalesce(exp::text,'NULL'),
    exp is not null and exp > now()+interval '59 days' and exp < now()+interval '61 days');

  -- T2: clinic ต่ออายุ (update expires_at) → ได้
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    update public.jobs set expires_at = now()+interval '60 days' where id=jid;
    get diagnostics ts=row_count; execute 'reset role';
    insert into _t6 values ('clinic ต่ออายุ (update expires_at)', ts::text||' row', ts>=1);
  exception when others then execute 'reset role'; insert into _t6 values ('clinic ต่ออายุ','EXC:'||sqlerrm,false); end;

  -- clinic สร้าง work_log + clinic_outcome=came (wl_ins gated) — สำหรับ test 2-party
  perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
  insert into public.work_logs(clinic_id,worker_id,job_id,work_date,clinic_outcome)
    values (cl,wk,jid,current_date,'came') returning id into lid;
  execute 'reset role';

  -- T3: หลัง insert (ฝ่ายเดียว) → status=pending + trust ยังไม่ขึ้น (กัน auto นับฝ่ายเดียว)
  select status into st from public.work_logs where id=lid;
  select trust_score into ts from public.worker_profiles where id=wk;
  insert into _t6 values ('ฝ่ายเดียว (clinic only) → pending + trust=0', 'status='||st||' trust='||ts, st='pending' and ts=0);

  -- T4: worker แก้ clinic_outcome ตรง ๆ → ต้อง ERROR (revoke update)
  begin
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    update public.work_logs set clinic_outcome='no_show' where id=lid;
    execute 'reset role'; insert into _t6 values ('worker direct UPDATE clinic_outcome (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t6 values ('worker direct UPDATE clinic_outcome (ต้อง fail)','errored ✓',true); end;

  -- T5: worker ยืนยันผ่าน RPC (worker_outcome=came) → confirmed + trust +1
  begin
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    perform public.set_work_outcome(lid, 'came');
    execute 'reset role';
    select status into st from public.work_logs where id=lid;
    select trust_score into ts from public.worker_profiles where id=wk;
    insert into _t6 values ('★ 2-party ตรง (came+came) → confirmed + trust+1', 'status='||st||' trust='||ts, st='confirmed' and ts=1);
  exception when others then execute 'reset role'; insert into _t6 values ('★ 2-party RPC confirm','EXC:'||sqlerrm,false); end;

  -- T6: RPC worker เซ็ต clinic_outcome ไม่ได้ (เซ็ตได้แค่ worker_outcome) — ลองงานใหม่ที่ไม่ตรง → disputed
  begin
    perform set_config('request.jwt.claims', clc, true); execute 'set local role authenticated';
    insert into public.work_logs(clinic_id,worker_id,job_id,work_date,clinic_outcome)
      values (cl,wk,jid,current_date - 1,'came') returning id into lid;
    execute 'reset role';
    -- worker ยืนยันเป็น no_show (ไม่ตรงกับ clinic=came) → disputed
    perform set_config('request.jwt.claims', wkc, true); execute 'set local role authenticated';
    perform public.set_work_outcome(lid, 'no_show');
    execute 'reset role';
    select status into st from public.work_logs where id=lid;
    select trust_score into ts from public.worker_profiles where id=wk;   -- ยังควร=1 (disputed ไม่นับ)
    insert into _t6 values ('ไม่ตรง (came vs no_show) → disputed + trust ไม่เพิ่ม', 'status='||st||' trust='||ts, st='disputed' and ts=1);
  exception when others then execute 'reset role'; insert into _t6 values ('mismatch → disputed','EXC:'||sqlerrm,false); end;

  -- T7: คนนอก (ไม่ใช่ทั้ง 2 ฝ่าย) เรียก RPC → ต้อง ERROR
  begin
    perform set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-0000000000ff','role','authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.set_work_outcome(lid, 'came');
    execute 'reset role'; insert into _t6 values ('คนนอกเรียก RPC (ต้อง fail)','NO ERROR (LEAK!)',false);
  exception when others then execute 'reset role'; insert into _t6 values ('คนนอกเรียก RPC (ต้อง fail)','errored ✓',true); end;

  delete from auth.users where id in (cl,wk);
end $$;
select * from _t6;
