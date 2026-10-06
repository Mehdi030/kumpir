// Erzeugt einen einmaligen Anmeldelink für ein Konto (ohne Mail, zählt nicht zum Mail-Limit).
//   node db/scripts/make-login-link.mjs medo [/profile]
import { readFileSync } from "node:fs";
const env = Object.fromEntries(readFileSync("apps/web/.env.local", "utf8").split(/\r?\n/).filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
const who = process.argv[2], next = process.argv[3] && !process.argv[3].startsWith("--") ? process.argv[3] : "/profile";
const base = (process.argv.find((a) => a.startsWith("--base=")) || "--base=https://kumpir-web.vercel.app").slice(7);
if (!who) { console.log("Aufruf: node db/scripts/make-login-link.mjs <benutzername|email> [/zielseite]"); process.exit(1); }
const S = env.SUPABASE_SERVICE_ROLE_KEY, U = env.NEXT_PUBLIC_SUPABASE_URL;
const h = { apikey: S, Authorization: `Bearer ${S}`, "Content-Type": "application/json" };
let email = who;
if (!who.includes("@")) {
    const r = await fetch(`${U}/rest/v1/profiles?username=eq.${encodeURIComponent(who.toLowerCase())}&select=email`, { headers: h });
    email = (await r.json())[0]?.email;
    if (!email) { console.log("Benutzername nicht gefunden."); process.exit(1); }
}
const r = await fetch(`${U}/auth/v1/admin/generate_link`, { method: "POST", headers: h, body: JSON.stringify({ type: "magiclink", email, redirect_to: `${base}/auth/callback?next=${encodeURIComponent(next)}` }) });
const j = await r.json();
console.log(j.action_link || JSON.stringify(j));
