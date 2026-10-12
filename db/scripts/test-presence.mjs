// Prüft den Online-Status live (Migration 103): Konto "Claude" lauscht auf friends:<id>,
// ein Wegwerf-Freund kommt online (touch_presence) – das Signal muss sofort ankommen.
//   node db/scripts/test-presence.mjs
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import pg from "pg";
import { createTestUser } from "./_test-users.mjs";

const env = (f) =>
    Object.fromEntries(
        readFileSync(f, "utf8")
            .split(/\r?\n/)
            .filter((l) => l.includes("=") && !l.startsWith("#"))
            .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
    );
const web = env("apps/web/.env.local");
const dbe = env("db/.env.local");
const URL_ = web.NEXT_PUBLIC_SUPABASE_URL;
const ANON = web.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const db = new pg.Client({ host: dbe.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: dbe.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
const q = async (sql, args = []) => (await db.query(sql, args)).rows;

const tok = await (
    await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
        method: "POST",
        headers: { apikey: ANON, "Content-Type": "application/json" },
        body: JSON.stringify({ email: dbe.CLAUDE_TEST_EMAIL, password: dbe.CLAUDE_TEST_PASSWORD }),
    })
).json();
if (!tok.access_token) throw new Error("Anmeldung fehlgeschlagen");
const me = tok.user.id;
const sb = createClient(URL_, ANON, { auth: { persistSession: false, autoRefreshToken: false } });
sb.realtime.setAuth(tok.access_token);

let got = null;
const ch = sb.channel(`friends:${me}`).on("broadcast", { event: "presence" }, () => (got ??= Date.now()));
await new Promise((res, rej) => ch.subscribe((s) => (s === "SUBSCRIBED" ? res() : s === "CHANNEL_ERROR" || s === "TIMED_OUT" ? rej(new Error(s)) : null)));

const friend = await createTestUser(q, `presence-test`);
let ok = false;
try {
    await q("insert into public.friendships (user_id, friend_user_id, status, accepted_at) values ($1,$2,'accepted',now()),($2,$1,'accepted',now())", [me, friend]);
    // Freund war lange weg und kommt jetzt online
    await q("begin");
    await q("select set_config('request.jwt.claims', $1, true), set_config('role', 'authenticated', true)", [JSON.stringify({ sub: friend, role: "authenticated" })]);
    const t0 = Date.now();
    await q("select public.touch_presence()");
    await q("commit");
    for (let i = 0; i < 50 && !got; i++) await sleep(100);
    ok = !!got;
    console.log(ok ? `✅ Online-Signal kam nach ${got - t0} ms an` : "❌ Kein Online-Signal angekommen");
    // Nochmal direkt danach: darf KEIN zweites Signal schicken (war ja gerade erst online)
    got = null;
    await q("begin");
    await q("select set_config('request.jwt.claims', $1, true), set_config('role', 'authenticated', true)", [JSON.stringify({ sub: friend, role: "authenticated" })]);
    await q("select public.touch_presence()");
    await q("commit");
    await sleep(2000);
    console.log(got ? "⚠️ Zweites Signal, obwohl schon online" : "✅ Kein doppeltes Signal");
} finally {
    await q("rollback").catch(() => {});
    await q("delete from auth.users where id = $1", [friend]);
    await sb.removeChannel(ch);
    await db.end();
}
process.exit(ok ? 0 : 1);
