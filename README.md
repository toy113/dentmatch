# DentMatch 🦷

เว็บแอปจับคู่ **คลินิกทันตกรรม ↔ ทันตบุคลากร** สำหรับงาน part-time ในไทย
ค้นหา/รับคำเชิญ แล้วกด **Add LINE** เพื่อคุยกันต่อใน LINE ภายนอก (ระบบไม่แชทเอง)
รองรับ 3 บทบาท: Guest / Clinic / Worker — Worker ใช้ **Anonymous ID** (เลข 4 หลัก) ปกป้องข้อมูลส่วนตัว

## วิธีเปิด

เปิดไฟล์ `index.html` ในเบราว์เซอร์ได้เลย (double-click หรือ Open with browser) — เป็น single-file app ไม่ต้องติดตั้งอะไร

> หากต้องการเปิดผ่าน local server (แนะนำให้ฟอนต์/พฤติกรรมตรงที่สุด):
> ```bash
> python -m http.server 8000
> ```
> แล้วเปิด http://localhost:8000

### มุมมองตัวอย่าง (Demo)
มีแถบ **"✨ โหมดตัวอย่าง"** ลอยอยู่ด้านล่าง กดสลับดูได้ทั้ง **Guest / Clinic / Worker** โดยไม่ต้องล็อกอิน

## หมายเหตุ

- 🧪 **เป็น demo / prototype** — ข้อมูลทั้งหมดเป็น **mock** (ลงประกาศ, คำเชิญ, work log ฯลฯ เป็น simulation)
- ยัง **ไม่ต่อ backend จริง** — production จะต่อ Supabase/PostgreSQL, เข้ารหัส PII, LINE Official, ฯลฯ
- แถบ "โหมดตัวอย่าง" และ flow ล็อกอิน mock จะถูกแทนที่ด้วย auth จริงเมื่อต่อ backend

## เทคโนโลยี

Single HTML file · Vanilla JS (ไม่มี framework) · Google Fonts (Prompt + Sarabun) · responsive 3 ระดับ (มือถือ / แท็บเล็ต / เดสก์ท็อป dashboard)
