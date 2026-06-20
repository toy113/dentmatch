// DentMatch — แจ้งเตือนงานใหม่ผ่าน LINE Bot (Messaging API push)
// คลินิกโพสต์งานสำเร็จ (index.html dmPostJob) → fire-and-forget เรียกฟังก์ชันนี้ด้วย { jobId }
// หา worker ที่ position ตรง + จังหวัดตรง (provinces[] หรือ province เดิม) + available=true + ผูก LINE ไว้แล้ว
// → push ข้อความสั้นแจ้งงานใหม่ (จำกัดจำนวนกันสแปม/ใช้โควต้า push เกิน)
//
// SECRET: ใช้ LINE_BOT_ACCESS_TOKEN เดียวกับ line-webhook (ตั้งไว้แล้ว)
// verify_jwt = true (default) — ต้อง login (clinic) ก่อนเรียกได้, ใช้ ANON_KEY+forward auth อ่าน jobs (เคารพ RLS)
//   แล้วสลับ service role เฉพาะตอน query worker_private (PII ข้าม user ต้องใช้ service role)

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';

const SUPABASE_URL      = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_ROLE      = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ACCESS_TOKEN      = Deno.env.get('LINE_BOT_ACCESS_TOKEN')!;

const MAX_NOTIFY = 30;   // กันสแปม/ใช้โควต้า LINE push เกินถ้างานตรงกับ worker จำนวนมาก

const DM_POS_LABEL: Record<string, string> = { dentist: 'ทันตแพทย์', assistant: 'ผู้ช่วยทันตแพทย์', counter: 'เคาน์เตอร์/ธุรการ' };

function corsHeaders(){
  return { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization,x-client-info, apikey, content-type' };
}

async function pushText(to: string, text: string){
  await fetch('https://api.line.me/v2/bot/message/push', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ACCESS_TOKEN}` },
    body: JSON.stringify({ to, messages: [{ type: 'text', text }] }),
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders() });
  try {
    const authHeader = req.headers.get('Authorization') || '';
    const { jobId } = await req.json();
    if (!jobId) return new Response(JSON.stringify({ error: 'jobId required' }), { status: 400, headers: corsHeaders() });

    // ผูกกับ JWT ผู้เรียก → RLS ทำงานเหมือนเรียกจาก browser ตรงๆ (jobs อ่านได้ทั้ง public + เจ้าของ)
    const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: job, error: jErr } = await sb.from('jobs')
      .select('id, title, position, province, wage_text').eq('id', jobId).single();
    if (jErr || !job) return new Response(JSON.stringify({ error: 'job not found' }), { status: 404, headers: corsHeaders() });

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { autoRefreshToken: false, persistSession: false } });

    // worker ตรง position + (province เดิม หรือ อยู่ใน provinces[]) + available + ยังไม่ถูกแจ้งงานนี้
    const { data: workers, error: wErr } = await admin.from('worker_profiles')
      .select('id, worker_private(line_user_id)')
      .eq('position', job.position)
      .eq('available', true)
      .or(`province.eq.${job.province},provinces.cs.{${job.province}}`)
      .limit(MAX_NOTIFY);
    if (wErr) return new Response(JSON.stringify({ error: 'query failed: ' + wErr.message }), { status: 500, headers: corsHeaders() });

    const posLabel = DM_POS_LABEL[job.position] || job.position;
    const text = `มีงานใหม่ตรงกับคุณ! 🦷\n${job.title}\n${posLabel} · ${job.province}${job.wage_text ? ' · ' + job.wage_text : ''}\nดูรายละเอียด/รับงานได้ที่ https://dentmatch.app/app`;

    let notified = 0;
    for (const w of workers || []) {
      const lid = (w as any).worker_private?.line_user_id;
      if (!lid) continue;
      try { await pushText(lid, text); notified++; } catch (_e) { /* คนเดียวพังไม่กระทบคนอื่น */ }
    }

    return new Response(JSON.stringify({ matched: (workers || []).length, notified }), { headers: { ...corsHeaders(), 'content-type': 'application/json' } });
  } catch (e) {
    return new Response(JSON.stringify({ error: 'server error: ' + (e instanceof Error ? e.message : String(e)) }), { status: 500, headers: corsHeaders() });
  }
});
