// Misst die Kommunikation im Spiel so, wie ein Browser sie erlebt (Konto "Claude", Anon-Key + Realtime):
//   * Dauer der Server-Aufrufe (Antwort senden, Herzschlag, Tick)
//   * Realtime: wie lange nach dem Weitergeben (Server-Zeitstempel) die Änderung beim Client ankommt
//   * Nachladen: Lobby- und Spieler-Abfrage, wie es die Spielseite nach jedem Ereignis macht
//
//   node db/scripts/test-latency.mjs   (1 Match gegen 3 Bots, Tempo Blitz, ~1–2 min)
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import pg from "pg";

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
const sb = createClient(URL_, ANON, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${tok.access_token}`, "x-kumpir-session": randomUUID() } },
});
sb.realtime.setAuth(tok.access_token);

const timings = {};
const timed = async (label, fn) => {
    const t0 = performance.now();
    const r = await fn();
    (timings[label] ??= []).push(performance.now() - t0);
    return r;
};
const rpc = (fn, args) => timed(`RPC ${fn}`, () => sb.rpc(fn, args));

// Uhr-Abgleich wie lib/serverClock.ts (beste von 5 Messungen)
let offset = 0, bestRtt = 1e9;
for (let i = 0; i < 5; i++) {
    const t0 = Date.now();
    const { data } = await sb.rpc("rpc_server_time");
    const t1 = Date.now();
    const srv = typeof data === "string" ? Date.parse(data) : Number(data);
    if (t1 - t0 < bestRtt && Number.isFinite(srv)) { bestRtt = t1 - t0; offset = srv - (t0 + t1) / 2; }
}
const serverNow = () => Date.now() + offset;

let r = await rpc("rpc_create_lobby", { p_host_name: "Claude", p_privacy: "private", p_max_players: 8, p_round_seconds: 25, p_user_id: tok.user.id, p_round_speed: "fast" });
const row = Array.isArray(r.data) ? r.data[0] : r.data;
const code = row.code, me = row.host_player_id;
await rpc("rpc_join_lobby", { p_code: code, p_player_id: me, p_name: "Claude", p_user_id: tok.user.id });
const { data: lob } = await sb.from("lobbies").select("id").eq("code", code).single();
const lobbyId = lob.id;
for (const [i, s] of [2, 2, 3].entries()) await rpc("rpc_add_bot", { p_lobby_id: lobbyId, p_me_player_id: me, p_bot_name: ["Bot Anna", "Bot Ben", "Bot Cleo"][i], p_skill: s });

// Realtime wie useLobbyRealtime.ts
const rt = [];
let lastHolderSince = null;
const ch = sb
    .channel(`lobby:${lobbyId}`)
    .on("postgres_changes", { event: "*", schema: "public", table: "lobbies", filter: `id=eq.${lobbyId}` }, (p) => {
        const n = p.new ?? {};
        if (n.holder_since && n.holder_since !== lastHolderSince) {
            lastHolderSince = n.holder_since;
            rt.push(serverNow() - Date.parse(n.holder_since));
        }
    })
    .on("postgres_changes", { event: "*", schema: "public", table: "players", filter: `lobby_id=eq.${lobbyId}` }, () => {})
    .subscribe();
// Broadcast aus der Datenbank (Migration 097)
const bc = [];
let lastBcHolderSince = null;
const ch2 = sb
    .channel(`kumpir:${lobbyId}`)
    .on("broadcast", { event: "lobby" }, (m) => {
        const n = m.payload ?? {};
        if (n.holder_since && n.holder_since !== lastBcHolderSince) {
            lastBcHolderSince = n.holder_since;
            bc.push(serverNow() - Date.parse(n.holder_since));
        }
    })
    .subscribe();
for (let i = 0; i < 40 && (ch.state !== "joined" || ch2.state !== "joined"); i++) await sleep(100);
console.log(`Realtime verbunden (${ch.state}), Uhr-Abgleich ±${Math.round(bestRtt / 2)} ms`);

await rpc("rpc_begin_topic_vote", { p_lobby_id: lobbyId, p_player_id: me });
let voted = false, handled = null, done = false, lastBeat = 0;
const started = Date.now();
while (!done && Date.now() - started > -1) {
    if (Date.now() - started > 4 * 60_000) break;
    // wie die Spielseite: Lobby laden, dann Spieler
    const lr = await timed("Nachladen Lobby", () => sb.from("lobbies").select("*").eq("code", code).single());
    const L = lr.data;
    await timed("Nachladen Spieler", () => sb.from("players").select("player_id,name,is_alive,status,seat_index,pass_count,tempo_pass_count,song_points").eq("lobby_id", lobbyId).eq("status", "active"));
    const now = Date.now();
    if (now - lastBeat > 4000) { lastBeat = now; void rpc("rpc_heartbeat", { p_lobby_id: lobbyId, p_player_id: me }); }
    if (L.phase === "topic_vote") {
        if (!voted) { voted = true; await rpc("rpc_vote_topic", { p_lobby_id: lobbyId, p_player_id: me, p_choice: 1 }); }
        if (L.topic_vote_ends_at && Date.parse(L.topic_vote_ends_at) <= serverNow()) await rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
    } else if (L.phase === "countdown") {
        if (L.countdown_ends_at && Date.parse(L.countdown_ends_at) <= serverNow()) await rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });
    } else if (L.phase === "running") {
        if (L.explode_at && Date.parse(L.explode_at) - 150 <= serverNow()) await rpc("rpc_tick_game", { p_code: code });
        if (L.holder_player_id === me && L.holder_since !== handled) {
            handled = L.holder_since;
            const [song] = await q("select title from song_pool where id = $1", [L.current_song_id]);
            await sleep(1500);
            await rpc("rpc_attempt_pass", { p_code: code, p_player_id: me, p_answer: song.title });
        }
    } else if (L.phase === "finished" || L.phase === "set_summary") done = true;
    await sleep(250);
}
await rpc("rpc_leave_lobby", { p_lobby_id: lobbyId, p_player_id: me });
await sb.removeChannel(ch);
await sb.removeChannel(ch2);
await db.end();

const stat = (a) => {
    const s = [...a].sort((x, y) => x - y);
    const p = (f) => Math.round(s[Math.min(s.length - 1, Math.floor(f * s.length))]);
    return `n=${s.length}  Median ${p(0.5)} ms  90% ${p(0.9)} ms  max ${Math.round(s[s.length - 1])} ms`;
};
console.log("\n⏱️ Messwerte");
for (const [k, v] of Object.entries(timings)) console.log(`  ${k.padEnd(34)} ${stat(v)}`);
if (rt.length) console.log(`  ${"Realtime: Weitergabe → Client".padEnd(34)} ${stat(rt)}`);
if (bc.length) console.log(`  ${"Broadcast: Weitergabe → Client".padEnd(34)} ${stat(bc)}`);
process.exit(0);
