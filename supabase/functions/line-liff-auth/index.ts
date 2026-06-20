// DentMatch — LIFF ID token verify → mint session (เสริม line-auth สำหรับเปิดผ่าน LINE in-app/LIFF)
// Frontend (อยู่ใน LIFF) เรียกด้วย POST { idToken } (จาก liff.getIDToken())
// ฟังก์ชันนี้ verify token กับ LINE (ไม่ต้องใช้ secret — /verify ใช้แค่ client_id)
// แล้ว mint OTP แบบเดียวกับ line-auth ให้ frontend แลกเป็น session เอง (verifyOtp)
//
// auto env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';

const LINE_CHANNEL_ID = '2010259716';   // public — ต้องตรงกับ aud ของ id_token (ผูก LIFF channel เดียวกัน)
const SUPABASE_URL     = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE     = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// อนุญาตเฉพาะ origin ของแอปจริง (LIFF เปิดจาก dentmatch.app เท่านั้น)
const ALLOWED_ORIGINS = ['http://localhost:8000', 'https://dentmatch.app'];

const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { autoRefreshToken: false, persistSession: false } });

function corsHeaders(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[1];
  return {
    'Access-Control-Allow-Origin': allow,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

Deno.serve(async (req) => {
  const headers = corsHeaders(req.headers.get('origin'));
  if (req.method === 'OPTIONS') return new Response(null, { headers });
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method' }), { status: 405, headers });

  try {
    const { idToken } = await req.json();
    if (!idToken) return new Response(JSON.stringify({ error: 'no_token' }), { status: 400, headers });

    // 1) verify id_token กับ LINE (ตรวจ signature/aud/exp ให้เสร็จในตัว)
    const verifyRes = await fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id_token: idToken, client_id: LINE_CHANNEL_ID }),
    });
    if (!verifyRes.ok) return new Response(JSON.stringify({ error: 'verify' }), { status: 401, headers });
    const claims = await verifyRes.json();
    const lineUserId: string = claims.sub;
    const displayName: string = claims.name || '';
    if (!lineUserId) return new Response(JSON.stringify({ error: 'no_userid' }), { status: 401, headers });

    // 2) หา/สร้าง user (synthetic email จาก line_user_id เดียวกับ flow OAuth เดิม → user เก่า match ได้)
    const email = `line_${lineUserId}@line.dentmatch.local`;
    const created = await admin.auth.admin.createUser({
      email, email_confirm: true,
      user_metadata: { provider: 'line', line_user_id: lineUserId, name: displayName },
    });
    if (created.error && !/already|registered|exists/i.test(created.error.message))
      return new Response(JSON.stringify({ error: 'create' }), { status: 500, headers });

    // 3) ออก magiclink OTP ให้ frontend แลกเป็น session (ไม่ส่งอีเมลจริง)
    const link = await admin.auth.admin.generateLink({ type: 'magiclink', email });
    if (link.error || !link.data?.user) return new Response(JSON.stringify({ error: 'link' }), { status: 500, headers });
    const userId = link.data.user.id;
    const otp = link.data.properties?.email_otp || '';

    // 4) เก่า/ใหม่ (อิงว่ามี profiles row ไหม)
    const { data: profileRow } = await admin.from('profiles').select('id').eq('id', userId).maybeSingle();
    const isNew = !profileRow;

    return new Response(JSON.stringify({ email, otp, isNew, name: displayName, lid: lineUserId }), { headers });
  } catch (_e) {
    return new Response(JSON.stringify({ error: 'server' }), { status: 500, headers });
  }
});
