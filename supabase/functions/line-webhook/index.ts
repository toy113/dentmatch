// DentMatch — LINE Bot webhook (Messaging API channel "Dentmatch" · แยกจาก LINE Login channel ที่ใช้ login/LIFF)
// LINE Console ต้องตั้ง Webhook URL = <SUPABASE_URL>/functions/v1/line-webhook + เปิด "Use webhook"
//
// SECRET (ตั้งด้วย: supabase secrets set LINE_BOT_CHANNEL_SECRET=xxxx LINE_BOT_ACCESS_TOKEN=xxxx) — ห้าม hardcode/commit
// verify_jwt = false (ตั้งตอน deploy ด้วย --no-verify-jwt) — LINE เรียกตรง ไม่มี Supabase JWT ส่งมา, ยืนยันตัวด้วย x-line-signature เอง

const CHANNEL_SECRET = Deno.env.get('LINE_BOT_CHANNEL_SECRET')!;
const ACCESS_TOKEN    = Deno.env.get('LINE_BOT_ACCESS_TOKEN')!;

async function verifySignature(body: string, signature: string | null): Promise<boolean> {
  if (!signature) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(CHANNEL_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sigBuf = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body));
  const expected = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
  return expected === signature;
}

async function replyText(replyToken: string, text: string) {
  await fetch('https://api.line.me/v2/bot/message/reply', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ACCESS_TOKEN}` },
    body: JSON.stringify({ replyToken, messages: [{ type: 'text', text }] }),
  });
}

const WELCOME = 'สวัสดีค่ะ 🦷 DentMatch แพลตฟอร์มจับคู่คลินิกทันตกรรม ↔ ทันตบุคลากร\nเปิดแอปได้ที่ https://dentmatch.app/app';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('ok', { status: 200 });
  const body = await req.text();
  const valid = await verifySignature(body, req.headers.get('x-line-signature'));
  if (!valid) return new Response('invalid signature', { status: 401 });

  let payload: any = {};
  try { payload = JSON.parse(body); } catch (_e) { return new Response('ok', { status: 200 }); }

  for (const ev of payload.events || []) {
    try {
      if (ev.type === 'follow' || (ev.type === 'message' && ev.message?.type === 'text')) {
        await replyText(ev.replyToken, WELCOME);
      }
    } catch (_e) { /* event เดียวพังไม่ให้กระทบ event อื่น — LINE ไม่ retry ทั้ง batch */ }
  }
  return new Response('ok', { status: 200 });
});
