#!/usr/bin/env node
// Prüft "Bot übernimmt, wenn jemand rausfliegt" (Migration 135) mit einer Test-Lobby (wird am Ende gelöscht):
// 40 s kein Lebenszeichen -> Bot -> Heartbeat bringt den Menschen zurück; Verlassen im Spiel -> Bot -> Wieder-Beitreten.
// Aufruf: node db/scripts/test-bot-takeover.mjs
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.includes("=") && !l.trim().startsWith("#"))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]),
);
const db = new pg.Client({
    host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false },
});
await db.connect();
const q = async (sql, a = []) => (await db.query(sql, a)).rows;
let failed = 0;
const check = (name, ok, detail = "") => {
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? "  – " + detail : ""}`);
    if (!ok) failed++;
};

let lobbyId = null;
try {
    const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Weg-Test', 'private', 12, 60)");
    [{ id: lobbyId }] = await q("select id from public.lobbies where code = $1", [code]);
    const guest = randomUUID();
    await q("select public.rpc_join_lobby($1::text, $2::uuid, 'Gast'::text, null::uuid)", [code, guest]);
    await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = 'buzzer', phase = 'quiz', series_index = 1, series_total = 1, run_started_at = now() where id = $1", [lobbyId]);
    const st = async (pid) => (await q("select is_bot, was_human, status, bot_skill from public.players where lobby_id = $1 and player_id = $2", [lobbyId, pid]))[0];

    // 1) Gast meldet sich 50 s nicht -> Bot
    await q("update public.players set last_seen_at = now() - interval '50 seconds' where lobby_id = $1 and player_id = $2", [lobbyId, guest]);
    await q("select public._away_tick()");
    let g = await st(guest);
    check("Gast ohne Lebenszeichen wird zum Bot", g.is_bot && g.was_human && g.status === "active", JSON.stringify(g));
    const h = await st(host);
    check("Host bleibt Mensch", !h.is_bot && !h.was_human);

    // 2) Gast meldet sich zurück (Heartbeat) -> wieder Mensch
    await q("select public.rpc_heartbeat($1, $2)", [lobbyId, guest]);
    g = await st(guest);
    check("Heartbeat bringt den Gast zurück", !g.is_bot && !g.was_human && g.status === "active", JSON.stringify(g));

    // 3) Gast verlässt das laufende Spiel -> Bot, Platz bleibt; Wieder-Beitreten -> Mensch
    await q("select public.rpc_leave_lobby($1, $2)", [lobbyId, guest]);
    g = await st(guest);
    check("Verlassen im Spiel: Bot übernimmt", g.is_bot && g.was_human && g.status === "active", JSON.stringify(g));
    await q("select public.rpc_join_lobby($1::text, $2::uuid, 'Gast'::text, null::uuid)", [code, guest]);
    g = await st(guest);
    check("Wieder-Beitreten: wieder Mensch", !g.is_bot && !g.was_human && g.status === "active", JSON.stringify(g));

    // 4) Einziger Mensch: nichts wird umgestellt (sonst wäre die Lobby leer)
    await q("update public.players set status = 'left' where lobby_id = $1 and player_id = $2", [lobbyId, guest]);
    await q("update public.players set last_seen_at = now() - interval '50 seconds' where lobby_id = $1 and player_id = $2", [lobbyId, host]);
    await q("select public._away_tick()");
    const h2 = await st(host);
    check("Einziger Mensch wird nicht zum Bot", !h2.is_bot && !h2.was_human, JSON.stringify(h2));

    // 5) In der Lobby (vor dem Spiel) bleibt alles wie bisher
    await q("update public.lobbies set phase = 'lobby' where id = $1", [lobbyId]);
    await q("update public.players set status = 'active', is_bot = false, was_human = false, last_seen_at = now() where lobby_id = $1", [lobbyId]);
    await q("select public.rpc_leave_lobby($1, $2)", [lobbyId, guest]);
    g = await st(guest);
    check("In der Lobby: Verlassen = weg (kein Bot)", g.status === "left" && !g.is_bot, JSON.stringify(g));

    // Einziger Mensch geht im Spiel: ganz normal weg (kein Bot, Lobby darf sich schließen)
    await q("update public.lobbies set phase = 'quiz' where id = $1", [lobbyId]);
    await q("update public.players set status = 'left' where lobby_id = $1 and player_id = $2", [lobbyId, guest]);
    await q("select public.rpc_leave_lobby($1, $2)", [lobbyId, host]);
    const h3 = await st(host);
    check("Einziger Mensch kann normal gehen (kein Bot)", !h3 || (h3.status === "left" && !h3.is_bot), JSON.stringify(h3));

    // 6) nur der Server darf _away_tick aufrufen
    const [{ ok }] = await q("select has_function_privilege('anon', 'public._away_tick()', 'execute') ok");
    check("_away_tick ist von außen gesperrt", ok === false);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    if (lobbyId) await q("delete from public.lobbies where id = $1", [lobbyId]).catch(() => {});
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
