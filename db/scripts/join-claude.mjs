// Claude tritt einer echten Lobby bei und spielt mit (über dieselben Schnittstellen wie der Browser).
//   node db/scripts/join-claude.mjs ABCD            (Lobby-Code)
//   node db/scripts/join-claude.mjs ABCD --skill=2   (1 = Anfänger, 2 = Mittel, 3 = Profi; Standard 2)
// Spielt, bis die Lobby weg ist oder 30 Minuten um sind. Nimmt automatisch an Revanche/weiteren Runden teil.
// Voraussetzung: Konto "Claude" (node db/scripts/play-claude.mjs --account-only).
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import pg from "pg";

const code = (process.argv[2] || "").toUpperCase();
if (!/^[A-Z0-9]{4}$/.test(code)) { console.log("Aufruf: node db/scripts/join-claude.mjs ABCD [--skill=1|2|3]"); process.exit(1); }
const skill = Number((process.argv.find((a) => a.startsWith("--skill=")) || "--skill=2").split("=")[1]);
// Trefferquote / Reaktionszeit (Sekunden) je Stärke
const PROFILE = { 1: { title: 0.55, artist: 0.15, min: 3.5, max: 7 }, 2: { title: 0.75, artist: 0.1, min: 2.5, max: 5.5 }, 3: { title: 0.9, artist: 0.05, min: 1.8, max: 3.8 } }[skill] ?? { title: 0.75, artist: 0.1, min: 2.5, max: 5.5 };
const WRONG = ["Kartoffelsalat", "Keine Ahnung", "Döner Song", "Lalala", "Ofenkartoffel Blues", "Quatsch mit Soße"];

const env = (f) => Object.fromEntries(readFileSync(f, "utf8").split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()]));
const web = env("apps/web/.env.local");
const dbe = env("db/.env.local");
if (!dbe.CLAUDE_TEST_EMAIL) { console.log('Kein Konto "Claude" – erst: node db/scripts/play-claude.mjs --account-only'); process.exit(1); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rnd = (a, b) => a + Math.random() * (b - a);

const t = await (await fetch(`${web.NEXT_PUBLIC_SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: "POST", headers: { apikey: web.NEXT_PUBLIC_SUPABASE_ANON_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email: dbe.CLAUDE_TEST_EMAIL, password: dbe.CLAUDE_TEST_PASSWORD }),
})).json();
if (!t.access_token) { console.log("Anmeldung fehlgeschlagen:", t.msg || t.error_description || JSON.stringify(t)); process.exit(1); }
const uid = t.user.id;
const sb = createClient(web.NEXT_PUBLIC_SUPABASE_URL, web.NEXT_PUBLIC_SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${t.access_token}`, "x-kumpir-session": randomUUID() } },
});
const db = new pg.Client({ host: dbe.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: dbe.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
const q = async (s, a = []) => (await db.query(s, a)).rows;
const rpc = async (fn, args) => { const { data, error } = await sb.rpc(fn, args); return { data, error: error?.message ?? null }; };
const say = (s) => console.log(`[${new Date().toLocaleTimeString("de-DE")}] ${s}`);

const [lobby] = await q("select id, phase from lobbies where code = $1", [code]);
if (!lobby) { console.log(`Lobby ${code} nicht gefunden.`); process.exit(1); }
const [prof] = await q("select coalesce(display_name, username) n from profiles where id = $1", [uid]);
const me = randomUUID();
const j = await rpc("rpc_join_lobby", { p_code: code, p_player_id: me, p_name: prof.n, p_user_id: uid });
if (j.error) { console.log("Beitritt fehlgeschlagen:", j.error); process.exit(1); }
const lobbyId = lobby.id;
say(`🤖 ${prof.n} ist Lobby ${code} beigetreten (Stärke ${skill}). Spiel jetzt starten!`);

let rematchAt = null, lastVoteKey = null, lastHolder = null, turn = 0, busy = false, lastBeat = 0, lastPhase = null;
const started = Date.now();

async function doTurn(holderSince) {
    const total = rnd(PROFILE.min, PROFILE.max);
    const r = Math.random();
    const mode = r < PROFILE.title ? "title" : r < PROFILE.title + PROFILE.artist ? "artist" : "wrong";
    const stillMine = async () => { const [L] = await q("select phase, holder_player_id, holder_since from lobbies where id = $1", [lobbyId]); return L.phase === "running" && L.holder_player_id === me && String(L.holder_since) === String(holderSince); };
    if (mode === "wrong" && Math.random() < 0.5) {
        await sleep(total * 400);
        if (!(await stillMine())) return;
        await rpc("rpc_attempt_pass", { p_code: code, p_player_id: me, p_answer: WRONG[Math.floor(Math.random() * WRONG.length)] });
        say(`   Zug ${turn}: Claude liegt daneben ❌`);
        await sleep(1300);
    }
    await sleep(total * 600);
    if (!(await stillMine())) return;
    const [L] = await q("select current_song_id from lobbies where id = $1", [lobbyId]);
    const [song] = await q("select title, artist from song_pool where id = $1", [L.current_song_id]);
    if (!song) return;
    if (mode === "wrong") { say(`   Zug ${turn}: Claude weiß es nicht 💥`); return; }
    const text = mode === "title" ? song.title.replace(/\s*\(.*?\)\s*/g, " ").trim() : song.artist.split(/\s*,\s*|\s*&\s*/)[0];
    const res = await rpc("rpc_attempt_pass", { p_code: code, p_player_id: me, p_answer: text });
    say(`   Zug ${turn}: Claude tippt "${text}" → ${res.error ? res.error : res.data == null ? "❌" : mode === "title" ? "✅ Titel" : "🟡 Interpret"}`);
}

for (;;) {
    if (Date.now() - started > 30 * 60_000) { say("30 Minuten um – Claude geht."); break; }
    const [L] = await q("select * from lobbies where id = $1", [lobbyId]);
    if (!L) { say("Lobby ist weg – Claude geht."); break; }
    const [mine] = await q("select status, is_alive from players where lobby_id = $1 and player_id = $2", [lobbyId, me]);
    if (!mine || mine.status !== "active") { say("Claude wurde aus der Lobby entfernt."); break; }
    const now = Date.now();
    if (now - lastBeat > 4000) { lastBeat = now; void rpc("rpc_heartbeat", { p_lobby_id: lobbyId, p_player_id: me }); }
    if (L.phase !== lastPhase) { lastPhase = L.phase; say(`Phase: ${L.phase}${L.round_number ? ` (Zug ${L.round_number})` : ""}`); }

    const due = (ts) => ts && new Date(ts).getTime() <= now;
    if (L.phase === "topic_vote") {
        const key = `${L.topic_vote_started_at}`;
        if (key !== lastVoteKey) { lastVoteKey = key; await sleep(rnd(800, 2500)); await rpc("rpc_vote_topic", { p_lobby_id: lobbyId, p_player_id: me, p_choice: 1 + Math.floor(Math.random() * 2) }); say("Claude hat abgestimmt"); }
        await rpc("rpc_maybe_shorten_topic_vote", { p_lobby_id: lobbyId });
        if (due(L.topic_vote_ends_at)) await rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
    } else if (L.phase === "countdown") {
        if (due(L.countdown_ends_at)) await rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });
    } else if (L.phase === "running") {
        if (L.explode_at && new Date(L.explode_at).getTime() - 150 <= now) await rpc("rpc_tick_game", { p_code: code });
        if (L.holder_player_id === me && !busy && String(L.holder_since) !== String(lastHolder)) {
            lastHolder = L.holder_since; turn++; busy = true;
            doTurn(L.holder_since).catch((e) => say("Fehler im Zug: " + e.message)).finally(() => (busy = false));
        }
    } else if (L.phase === "set_summary") {
        if (due(L.countdown_ends_at)) await rpc("rpc_start_next_set", { p_code: code });
    } else if (L.phase === "finished") {
        // Nach dem Matchende: nach ein paar Sekunden "Revanche" drücken (wie ein Mensch am Endbildschirm)
        if (!rematchAt) rematchAt = now + 6000;
        if (now >= rematchAt) { rematchAt = null; await rpc("rpc_rematch", { p_code: code, p_player_id: me }); say("Claude will Revanche 🔁"); }
    } else if (L.phase === "rematch_wait") {
        if (due(L.countdown_ends_at)) await rpc("rpc_start_rematch_if_ready", { p_code: code });
    }
    await sleep(300);
}
await rpc("rpc_leave_lobby", { p_lobby_id: lobbyId, p_player_id: me });
await db.end();
process.exit(0);
