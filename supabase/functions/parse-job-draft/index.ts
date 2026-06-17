// DentMatch — parse-job-draft (Edge Function)
// แอดมินกด "ดึงข้อมูลอัตโนมัติ" ในหน้า v-admin → เรียกฟังก์ชันนี้ → ใช้ Claude แยกข้อความ LINE OpenChat ดิบ
// เป็น job card draft (jsonb) แล้วบันทึกกลับ job_drafts.parsed
//
// SECRET (ตั้งด้วย: supabase secrets set ANTHROPIC_API_KEY=xxxx) — ห้าม hardcode/commit
// verify_jwt = true (default ไม่ตั้งใน config.toml) → ต้อง login ก่อนเรียกได้ + เช็ค is_dm_admin() อีกชั้น (RLS เดียวกับ job_drafts)
// ใช้ ANON_KEY + forward Authorization header ของผู้เรียก → RLS ทำงานเหมือนเรียกจาก client ตรงๆ (ไม่ใช้ service role เกินจำเป็น)

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';

const SUPABASE_URL      = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;

const EXTRACT_TOOL = {
  name: 'extract_job_post',
  description: 'แยกข้อมูลประกาศงานทันตกรรมจากข้อความแชท LINE OpenChat (ภาษาไทย) — ถ้าข้อความไม่ใช่ประกาศงาน (เช่น ทักทาย/ถามคำถาม/แชทเล่น) ให้ is_job_post=false และเว้นฟิลด์อื่นว่างได้',
  input_schema: {
    type: 'object',
    properties: {
      is_job_post:      { type: 'boolean', description: 'ใช่ประกาศรับสมัครงานทันตกรรมหรือไม่' },
      confidence:       { type: 'number', description: 'ความมั่นใจ 0-1' },
      clinic_name_text: { type: 'string', description: 'ชื่อคลินิกที่ระบุในข้อความ (ถ้ามี)' },
      title:            { type: 'string', description: 'หัวข้อประกาศงานสั้นๆ' },
      position:         { type: 'string', enum: ['dentist', 'assistant', 'counter'], description: 'ทันตแพทย์=dentist, ผู้ช่วยทันตแพทย์=assistant, เคาน์เตอร์/ธุรการ=counter' },
      province:         { type: 'string', description: 'จังหวัด (ชื่อเต็มภาษาไทย เช่น กรุงเทพมหานคร)' },
      district:         { type: 'string' },
      wage_text:        { type: 'string', description: 'ค่าจ้างตามที่ระบุ เช่น 600/วัน' },
      work_days:        { type: 'array', items: { type: 'integer', minimum: 1, maximum: 7 }, description: 'วันทำงานประจำ 1=จันทร์ ... 7=อาทิตย์ (ใส่เมื่อเป็นวันประจำรายสัปดาห์)' },
      work_dates:       { type: 'array', items: { type: 'string' }, description: 'วันที่ทำงานเจาะจง รูปแบบ YYYY-MM-DD แบบปี ค.ศ. เสมอ (ใส่เมื่อระบุวันที่ตรงตัว ไม่ใช่วันประจำ) — สำคัญ: ข้อความมักเป็นปี พ.ศ. (เช่น "สิงหาคม 2569") ต้องแปลงเป็น ค.ศ. โดยลบ 543 ก่อน (2569→2026) · ถ้าไม่ระบุปี ให้อนุมานปีปัจจุบัน/ปีถัดไปที่ใกล้ที่สุด' },
      time_start:       { type: 'string', description: 'เวลาเริ่ม HH:MM' },
      time_end:         { type: 'string', description: 'เวลาเลิก HH:MM' },
      contact_line_id:  { type: 'string', description: 'LINE ID ติดต่อ ถ้ามีระบุ' },
    },
    required: ['is_job_post', 'confidence'],
  },
};

function corsHeaders(){
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization,x-client-info, apikey, content-type',
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders() });
  try {
    const authHeader = req.headers.get('Authorization') || '';
    const { draftId } = await req.json();
    if (!draftId) return new Response(JSON.stringify({ error: 'draftId required' }), { status: 400, headers: corsHeaders() });

    // client ผูกกับ JWT ของผู้เรียก → RLS (is_dm_admin()) ทำงานเหมือนเรียกจาก browser ตรงๆ
    const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: draft, error: dErr } = await sb.from('job_drafts').select('id, raw_message').eq('id', draftId).single();
    if (dErr || !draft) return new Response(JSON.stringify({ error: 'draft not found หรือไม่มีสิทธิ์ (ต้องเป็นแอดมิน)' }), { status: 403, headers: corsHeaders() });

    const aiRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 1024,
        tools: [EXTRACT_TOOL],
        tool_choice: { type: 'tool', name: 'extract_job_post' },
        messages: [{
          role: 'user',
          content: `ข้อความจากกลุ่ม LINE OpenChat หางานทันตกรรม:\n\n"""\n${draft.raw_message}\n"""\n\nแยกข้อมูลประกาศงานตาม schema ที่กำหนด`,
        }],
      }),
    });
    if (!aiRes.ok) {
      const t = await aiRes.text();
      return new Response(JSON.stringify({ error: 'AI request failed: ' + t.slice(0, 300) }), { status: 502, headers: corsHeaders() });
    }
    const aiJson = await aiRes.json();
    const toolUse = (aiJson.content || []).find((c: any) => c.type === 'tool_use');
    if (!toolUse) return new Response(JSON.stringify({ error: 'no structured result from AI' }), { status: 502, headers: corsHeaders() });
    const parsed = toolUse.input;

    // กันพลาด: AI อาจคืนวันที่เป็นปี พ.ศ. (เช่น 2569-08-01) → แปลงเป็น ค.ศ. (ปี ≥ 2500 ลบ 543)
    if (Array.isArray(parsed.work_dates)) {
      parsed.work_dates = parsed.work_dates.map((d: any) => {
        const m = /^(\d{4})(-\d{2}-\d{2})/.exec(String(d || '').trim());
        if (!m) return d;
        const y = +m[1];
        return y >= 2500 ? (y - 543) + m[2] : d;
      });
    }

    const { error: uErr } = await sb.from('job_drafts').update({
      parsed,
      clinic_name_text: parsed.clinic_name_text || null,
    }).eq('id', draftId);
    if (uErr) return new Response(JSON.stringify({ error: 'save failed: ' + uErr.message }), { status: 500, headers: corsHeaders() });

    return new Response(JSON.stringify({ parsed }), { status: 200, headers: { ...corsHeaders(), 'content-type': 'application/json' } });
  } catch (e) {
    return new Response(JSON.stringify({ error: 'server error: ' + (e instanceof Error ? e.message : String(e)) }), { status: 500, headers: corsHeaders() });
  }
});
