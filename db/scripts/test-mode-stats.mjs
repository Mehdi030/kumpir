#!/usr/bin/env node
// Prüft die Modus-Statistik für Buzzer und Jahr raten (Migration 133) mit einer Test-Lobby (wird am Ende gelöscht):
// Spiel beenden -> quiz_mode_matches gefüllt (gewertet bei 2 Menschen, Übung bei 1) -> get_my_mode_stats.
// Aufruf: node db/scripts/test-mode-stats.mjs
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

const [acc] = await q("select id from public.profiles where lower(username) = 'claude'");
const ids = [];
const matchIds = [];
try {
    if (!acc) throw new Error("Testkonto 'claude' fehlt");
    for (const [mode, twoHumans] of [["buzzer", true], ["year", false]]) {
        const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Statistik', 'private', 12, 60)");
        const [{ id }] = await q("select id from public.lobbies where code = $1", [code]);
        ids.push(id);
        await q("select public.rpc_add_bot($1, $2, 'Bot 1', 2::smallint)", [id, host]);
        await q("update public.players set user_id = $2 where lobby_id = $1 and player_id = $3", [id, acc.id, host]);
        if (twoHumans) await q("update public.players set is_bot = false where lobby_id = $1 and is_bot", [id]);
        await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = $2, phase = 'quiz', series_index = 1, series_total = 1, run_started_at = now(), quiz_seq = 3 where id = $1", [id, mode]);
        await q("update public.players set song_points = 12 where lobby_id = $1 and player_id = $2", [id, host]);
        // 3 Antworten: Buzzer = 2 richtig; Jahr = 1 Volltreffer
        for (const [seq, ok, pts] of [[1, true, 5], [2, true, 3], [3, false, 0]]) {
            await q("insert into public.quiz_answers (lobby_id, seq, player_id, answer, num, correct, points, tries) values ($1, $2, $3, 'x', 1, $4, $5, 1)", [id, seq, host, ok, pts]);
        }
        await q("select public._quiz_finish($1)", [id]);
        const rows = await q("select * from public.quiz_mode_matches where lobby_id = $1 and user_id = $2", [id, acc.id]);
        matchIds.push(id);
        const r = rows[0];
        const expectHits = mode === "buzzer" ? 2 : 1;
        check(`${mode}: Spiel festgehalten (${twoHumans ? "gewertet" : "Übung"})`, !!r && r.mode === mode && r.ranked === twoHumans && r.hits === expectHits && r.answers === 3 && Number(r.total) === 12, JSON.stringify(r));
    }
    // Auswertung wie ein angemeldeter Client
    await db.query("begin");
    await db.query("select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.sub', $2, true), set_config('role', 'authenticated', true)", [JSON.stringify({ sub: acc.id, role: "authenticated" }), acc.id]);
    const st = (await db.query("select public.get_my_mode_stats() s")).rows[0].s;
    await db.query("rollback");
    check("get_my_mode_stats: Buzzer gewertet + Jahr als Übung", st.buzzer?.matches >= 1 && st.year?.practice >= 1 && st.buzzer?.hits >= 2, JSON.stringify(st).slice(0, 200));
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
    await db.query("rollback").catch(() => {});
} finally {
    for (const id of ids) {
        await q("delete from public.quiz_mode_matches where lobby_id = $1", [id]).catch(() => {});
        await q("delete from public.player_achievements where lobby_id = $1", [id]).catch(() => {});
        await q("delete from public.lobbies where id = $1", [id]).catch(() => {});
    }
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
