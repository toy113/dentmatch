// DentMatch — LINE Login callback (Batch 3)
// LINE ไม่ใช่ provider สำเร็จรูป → frontend เปิด authorize เอง (Channel ID public),
// redirect_uri = ฟังก์ชันนี้ /callback → แลก code (ใช้ secret) → mint session → redirect กลับแอป
//
// SECRET (ตั้งด้วย: supabase secrets set LINE_CHANNEL_SECRET=xxxx) — ห้าม hardcode/commit
// auto env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// Channel ID เป็น public (ใส่ตรงนี้ + frontend ได้)
//
// ★ ลงทะเบียนใน LINE Console (Callback URL): <SUPABASE_URL>/functions/v1/line-auth/callback

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';   // npm: = Supabase edge best practice · cache ดีกว่า esm.sh → cold start เร็วขึ้น

const LINE_CHANNEL_ID     = '2010259716';                                   // public
const LINE_CHANNEL_SECRET = Deno.env.get('LINE_CHANNEL_SECRET')!;           // secret (env เท่านั้น)
const SUPABASE_URL        = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE        = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CALLBACK_URL        = `${SUPABASE_URL}/functions/v1/line-auth/callback`;

// allowlist กัน open-redirect (เพิ่ม origin ของแอปที่อนุญาตให้ส่ง session กลับ)
const ALLOWED_ORIGINS = [
  'http://localhost:8000',
  'https://dentmatch.vercel.app',
];
const DEFAULT_RETURN = 'https://dentmatch.vercel.app/';

const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { autoRefreshToken: false, persistSession: false } });

function b64urlDecode(s: string){ try{ s=s.replace(/-/g,'+').replace(/_/g,'/'); return JSON.parse(atob(s)); }catch(_){ return {}; } }
function safeReturn(ret: string){
  try{ const u=new URL(ret); if(ALLOWED_ORIGINS.includes(u.origin)) return u.origin+u.pathname; }catch(_){}
  return DEFAULT_RETURN;
}
function redirectBack(ret: string, hash: string){
  const back=new URL(safeReturn(ret)); back.hash=hash; return Response.redirect(back.toString(), 302);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (!url.pathname.endsWith('/callback')) return new Response('not found', { status: 404 });

  const code  = url.searchParams.get('code');
  const ret   = b64urlDecode(url.searchParams.get('state') || '').ret || '';
  if (!code) return redirectBack(ret, 'line_error=no_code');

  try {
    // 1) แลก code -> token
    const tokenRes = await fetch('https://api.line.me/oauth2/v2.1/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code', code, redirect_uri: CALLBACK_URL,
        client_id: LINE_CHANNEL_ID, client_secret: LINE_CHANNEL_SECRET,
      }),
    });
    if (!tokenRes.ok) return redirectBack(ret, 'line_error=token');
    const token = await tokenRes.json();

    // 2) ดึง profile (userId = line_user_id)
    const profRes = await fetch('https://api.line.me/v2/profile', {
      headers: { Authorization: `Bearer ${token.access_token}` },
    });
    if (!profRes.ok) return redirectBack(ret, 'line_error=profile');
    const prof = await profRes.json();
    const lineUserId: string = prof.userId;
    const displayName: string = prof.displayName || '';
    if (!lineUserId) return redirectBack(ret, 'line_error=no_userid');

    // 3) หา/สร้าง user (synthetic email จาก line_user_id = key คงที่ → user เก่า match ได้)
    const email = `line_${lineUserId}@line.dentmatch.local`;
    const created = await admin.auth.admin.createUser({
      email, email_confirm: true,
      user_metadata: { provider: 'line', line_user_id: lineUserId, name: displayName },
    });
    if (created.error && !/already|registered|exists/i.test(created.error.message))
      return redirectBack(ret, 'line_error=create');

    // 4) ออก magiclink OTP ให้ frontend แลกเป็น session (ไม่ส่งอีเมลจริง)
    const link = await admin.auth.admin.generateLink({ type: 'magiclink', email });
    if (link.error || !link.data?.user) return redirectBack(ret, 'line_error=link');
    const userId = link.data.user.id;
    const otp = link.data.properties?.email_otp || '';

    // 5) เก่า/ใหม่ (อิงว่ามี profiles row ไหม)
    const { data: profileRow } = await admin.from('profiles').select('id').eq('id', userId).maybeSingle();
    const isNew = !profileRow;

    return redirectBack(ret,
      `line=1&email=${encodeURIComponent(email)}&otp=${encodeURIComponent(otp)}&new=${isNew?1:0}` +
      `&name=${encodeURIComponent(displayName)}&lid=${encodeURIComponent(lineUserId)}`);
  } catch (e) {
    return redirectBack(ret, 'line_error=server');
  }
});
