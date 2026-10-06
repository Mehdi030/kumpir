#!/usr/bin/env node
/**
 * Testet Migration 086 (Freunde mit Online-Status) in EINER Transaktion, die zurückgerollt wird.
 * Aufruf: node db/scripts/test-friends-status.mjs
 */
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import pg from "pg";
import { createTestUser } from "./_test-users.mjs";

const env = Object.fromEntries(readFileSync("db/.env.local", "utf8").split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]));
const c = new pg.Client({ host: env.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (s, p) => (await c.query(s, p)).rows;
let failed = 0;
const check = (n, ok, d = "") => {
    console.log(`${ok ? "✅" : "❌"} ${n}${d ? "  – " + d : ""}`);
    if (!ok) failed++;
};
let sp = 0;
async function as(uid, sql, params) {
    const name = `s${++sp}`;
    await q(`savepoint ${name}`);
    try {
        await q("set local role authenticated");
        await q("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(uid ? { sub: uid, role: "authenticated" } : { role: "anon" })]);
        const rows = await q(sql, params);
        await q("reset role");
        await q("select set_config('request.jwt.claims', '', true)");
        await q(`release savepoint ${name}`);
        return { rows };
    } catch (e) {
        await q(`rollback to savepoint ${name}`);
        await q("reset role");
        return { error: e.message };
    }
}

try {
    await q("begin");
    const me = await createTestUser(q, "fme");
    const anna = await createTestUser(q, "fanna");   // online per Meldung
    const ben = await createTestUser(q, "fben");     // offline
    const cleo = await createTestUser(q, "fcleo");   // in offener Lobby
    const stranger = await createTestUser(q, "fstranger"); // kein Freund, aber online
    for (const f of [anna, ben, cleo]) {
        await q("insert into friendships (user_id, friend_user_id, status, accepted_at) values ($1, $2, 'accepted', now()), ($2, $1, 'accepted', now())", [me, f]);
    }
    await q("update profiles set avatar_emoji = '🎧', avatar_color = '#22c55e' where id = $1", [anna]);

    // Anmeldung/Meldung
    let r = await as(anna, "select public.touch_presence()");
    check("Konto kann sich als anwesend melden", !r.error, r.error);
    r = await as(stranger, "select public.touch_presence()");
    r = await as(null, "select public.touch_presence()");
    check("Gast: touch_presence tut nichts (kein Fehler, kein Eintrag)", (await q("select count(*)::int n from user_presence where user_id is null"))[0].n === 0);
    r = await as(null, "select public.get_friends_status() a");
    check("Gast bekommt keine Freunde", !r.error && JSON.stringify(r.rows?.[0]?.a) === "[]", r.error);

    // Cleo sitzt in einer offenen Lobby
    const [lob] = await q("select * from public.rpc_create_lobby('CleoHost', 'private', 6, 25, null, 'normal')");
    const [{ id: lobbyId }] = await q("select id from lobbies where code = $1", [lob.code]);
    const cleoPid = randomUUID();
    await q("select public.rpc_join_lobby($1, $2, 'Cleo', null)", [lob.code, cleoPid]);
    await q("update players set user_id = $3, last_seen_at = now() where lobby_id = $1 and player_id = $2", [lobbyId, cleoPid, cleo]);

    r = await as(me, "select public.get_friends_status() a");
    const list = r.rows?.[0]?.a ?? [];
    check("Nur eigene Freunde (3), kein Fremder", !r.error && list.length === 3 && !list.some((x) => x.username === "fstranger"), list.map((x) => x.username).join(","));
    const names = list.map((x) => x.username).join(",");
    check("Online zuerst, dann alphabetisch", names === "fanna,fcleo,fben", names);
    const a = list.find((x) => x.username === "fanna");
    check("Anna: online, mit Avatar", a?.online === true && a?.avatarEmoji === "🎧" && a?.avatarColor === "#22c55e", JSON.stringify(a));
    const b = list.find((x) => x.username === "fben");
    check("Ben: offline", b?.online === false && b?.lobbyCode === null);
    const cl = list.find((x) => x.username === "fcleo");
    check("Cleo: online durch Lobby, Code und beitretbar", cl?.online === true && cl?.lobbyCode === lob.code && cl?.joinable === true, JSON.stringify(cl));

    // gesperrte/unsichtbare Konten tauchen nicht auf
    await q("update profiles set status = 'suspended' where id = $1", [ben]);
    r = await as(me, "select public.get_friends_status() a");
    check("Gesperrte Konten werden nicht angezeigt", (r.rows?.[0]?.a ?? []).length === 2);

    // Sperre auf die Tabellen
    r = await as(me, "select * from public.user_presence");
    check("user_presence direkt nicht lesbar", !!r.error, r.error);
    r = await as(me, "update public.user_presence set last_seen_at = now()");
    check("user_presence direkt nicht schreibbar", !!r.error, r.error);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await c.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
