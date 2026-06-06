-- DentMatch — 0010 · Realtime publication (กระดิ่งเด้งสด · ต่อยอด C4f)
-- รันหลัง 0001-0009
-- C4f เดิม: noti "derive ตอนโหลด" → upgrade: frontend subscribe realtime → re-derive อัตโนมัติเมื่อมีของใหม่
-- ตารางที่ noti ใช้: invites · work_logs (worker) ; add_line_events · invites (clinic)
-- RLS เดิม (inv_sel/wl_sel/ale_sel = party-scoped) คุมผู้รับ realtime อยู่แล้ว → ได้เฉพาะแถวที่ตัวเอง SELECT ได้
-- frontend ยัง filter ด้วย worker_id/clinic_id อีกชั้น (ลด noise) · ไม่แตะ schema/policy/protected fields เดิม

-- ════════ 1) เพิ่ม 3 ตารางเข้า publication supabase_realtime (idempotent — กัน add ซ้ำ error) ════════
-- หมายเหตุ: Supabase สร้าง publication 'supabase_realtime' (แบบ empty) ให้อยู่แล้ว — เราแค่ add table
do $$
declare t text; tbls text[] := array['invites','work_logs','add_line_events'];
begin
  if not exists (select 1 from pg_publication where pubname='supabase_realtime') then
    create publication supabase_realtime;   -- เผื่อ project/self-host ที่ยังไม่มี
  end if;
  foreach t in array tbls loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ════════ 2) REPLICA IDENTITY FULL : ให้ realtime ส่ง UPDATE/DELETE ผ่าน RLS ได้ครบ ════════
-- clinic ฟัง invites.status → 'accepted' (UPDATE) · worker ฟัง work_logs outcome (UPDATE)
-- ต้องมี full ไม่งั้น RLS ประเมิน row เก่าไม่ได้ → event UPDATE/DELETE ไม่ถูกส่ง
-- add_line_events = INSERT-only → DEFAULT (PK) พอ ไม่ต้อง full
alter table public.invites   replica identity full;
alter table public.work_logs replica identity full;

-- ============================================================
-- TEST (_t10 : pass ต้อง true ทั้งหมด)
-- ============================================================
drop table if exists _t10;
create temp table _t10(test text, result text, pass boolean);
do $$
declare n int; t text; tbls text[] := array['invites','work_logs','add_line_events'];
begin
  -- T1: 3 ตารางอยู่ใน publication supabase_realtime
  select count(*) into n from pg_publication_tables
   where pubname='supabase_realtime' and schemaname='public' and tablename = any(tbls);
  insert into _t10 values ('3 ตารางอยู่ใน supabase_realtime', n::text||'/3', n=3);

  -- T2: idempotent — รัน guarded-add ซ้ำ ต้องไม่ error และยังครบ 3
  begin
    foreach t in array tbls loop
      if not exists (select 1 from pg_publication_tables
        where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
    insert into _t10 values ('รัน add ซ้ำ (guarded) ไม่ error', 'ok', true);
  exception when others then
    insert into _t10 values ('รัน add ซ้ำ (guarded) ไม่ error', 'EXC:'||sqlerrm, false);
  end;

  -- T3: invites + work_logs = REPLICA IDENTITY FULL (relreplident='f')
  select count(*) into n from pg_class
   where relname in ('invites','work_logs')
     and relnamespace = 'public'::regnamespace and relreplident = 'f';
  insert into _t10 values ('invites+work_logs = REPLICA IDENTITY FULL', n::text||'/2', n=2);
end $$;
select * from _t10;
