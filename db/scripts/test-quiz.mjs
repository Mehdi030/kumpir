#!/usr/bin/env node
// Quiz-Modi mit 4 Bots durchspielen (Server-Takt + Bot-Takt laufen per Cron).
// Aufruf: node db/scripts/test-quiz.mjs <mode>   (original|buzzer|year), KEEP=1 = Lobby nicht löschen
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.includes("=") && !l.trim().startsWith("#"))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]),
);
const mode = process.argv[2] || "buzzer";
const db = new pg.Client({
    host: env.SUPABASE_DB_HOST,
    port: Number(env.SUPABASE_DB_PORT || 5432),
    database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres",
    password: env.SUPABASE_DB_PASSWORD,
    ssl: { rejectUnauthorized: false },
});
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
await db.connect();
const q = async (sql, args = []) => (await db.query(sql, args)).rows;

const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('QuizTest', 'private', 8, 60)");
const [{ id }] = await q("select id from public.lobbies where code = $1", [code]);
for (const n of ["Bot A", "Bot B", "Bot C"]) await q("select public.rpc_add_bot($1, $2, $3, 3::smallint)", [id, host, n]);
// Host ist auch ein Bot, damit alle antworten
await q("update public.players set is_bot = true, bot_skill = 2 where player_id = $1", [host]);
await q(
    `update public.lobbies set game_mode = $2, topic_selected = 'Deutschrap aktuell', phase = 'countdown',
       countdown_ends_at = now(), series_index = 1, series_total = 1 where id = $1`,
    [id, mode],
);
await q("select public.rpc_advance_from_countdown($1)", [id]);
console.log("Lobby", code, "Modus", mode);

let last = "";
const t0 = Date.now();
for (;;) {
    const [l] = await q("select phase, quiz_state, quiz_index, quiz_total, quiz_options, quiz_reveal from public.lobbies where id = $1", [id]);
    const key = `${l.phase}/${l.quiz_state}/${l.quiz_index}`;
    if (key !== last) {
        last = key;
        const extra = l.quiz_state === "reveal" ? JSON.stringify({ t: l.quiz_reveal?.title, a: l.quiz_reveal?.artist, y: l.quiz_reveal?.year, w: l.quiz_reveal?.word, r: (l.quiz_reveal?.results || []).map((x) => x.points), pb: l.quiz_reveal?.pickerBonus, dw: l.quiz_reveal?.duelWinner }) : JSON.stringify(l.quiz_options);
        console.log(((Date.now() - t0) / 1000).toFixed(1).padStart(6), key, extra?.slice(0, 220));
    }
    if (l.phase === "finished" || l.phase === "set_summary") break;
    if (l.phase !== "quiz" && l.phase !== "running" && l.phase !== "countdown") break;
    if (Date.now() - t0 > 600000) { console.log("Timeout"); break; }
    await wait(700);
}
console.log(await q("select name, song_points, is_alive from public.players where lobby_id = $1 order by song_points desc", [id]));
console.log(await q("select name, place, arena_points, song_points from public.series_results where lobby_id = $1 order by place", [id]));
if (process.env.KEEP) console.log("Lobby bleibt:", code);
else await q("delete from public.lobbies where id = $1", [id]);
await db.end();
