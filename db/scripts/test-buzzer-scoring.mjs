#!/usr/bin/env node
// Prüft die Buzzer-Wertung (Migration 140) mit einer Test-Lobby (wird am Ende gelöscht):
// Künstler 0,25 – Titel 1 – Titel + Künstler 1,25 – falsch -0,5 (nie unter 0) – Kommazahlen bleiben in Summen erhalten.
// Aufruf: node db/scripts/test-buzzer-scoring.mjs
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
let lobbyId = null;
try {
    const [song] = await q("select id, title, artist from public.song_pool where archived_from is null and title ~ '^[A-Za-z]{7,}$' and artist ~ '^[A-Za-z]{5,}$' limit 1");
    const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Wertung', 'private', 12, 60)");
    [{ id: lobbyId }] = await q("select id from public.lobbies where code = $1", [code]);
    await q("select public.rpc_add_bot($1, $2, 'Bot 1', 2::smallint)", [lobbyId, host]);
    await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = 'buzzer', phase = 'quiz', series_index = 1, series_total = 1, run_started_at = now(), quiz_seq = 1, quiz_index = 1, quiz_total = 20, quiz_target = 10 where id = $1", [lobbyId]);
    await q("insert into public.quiz_secret (lobby_id, seq, song_id) values ($1, 1, $2) on conflict (lobby_id) do update set song_id = excluded.song_id, seq = 1", [lobbyId, song.id]);

    const play = async (answer, startPoints = 0) => {
        await q("delete from public.quiz_answers where lobby_id = $1", [lobbyId]);
        await q("update public.players set song_points = $3 where lobby_id = $1 and player_id = $2", [lobbyId, host, startPoints]);
        await q("update public.lobbies set quiz_state = 'buzzed', quiz_picker = $2, quiz_locked = '{}', quiz_ends_at = now() + interval '30 seconds', quiz_seq = 1, phase = 'quiz' where id = $1", [lobbyId, host]);
        const [{ r }] = await q("select public._quiz_do_answer($1, $2, $3) r", [lobbyId, host, answer]);
        const [{ sp }] = await q("select song_points::float sp from public.players where lobby_id = $1 and player_id = $2", [lobbyId, host]);
        return { r, sp };
    };

    let t = await play(song.artist);
    check("Nur Künstler = 0,25 Punkte", t.r.correct && Number(t.r.points) === 0.25 && t.sp === 0.25, JSON.stringify(t));
    t = await play(song.title);
    check("Titel = 1 Punkt", t.r.correct && Number(t.r.points) === 1 && t.sp === 1, JSON.stringify(t));
    t = await play(`${song.artist} ${song.title}`);
    check("Titel + Künstler = 1,25 Punkte", t.r.correct && Number(t.r.points) === 1.25 && t.sp === 1.25, JSON.stringify(t));
    t = await play("völlig falsch xyz", 3);
    check("Falsch = −0,5 (von 3 auf 2,5)", !t.r.correct && Number(t.r.points) === -0.5 && t.sp === 2.5, JSON.stringify(t));
    t = await play("völlig falsch xyz", 0.25);
    check("Falsch bei 0,25 Punkten: nur −0,25, nie unter 0", Number(t.r.points) === -0.25 && t.sp === 0, JSON.stringify(t));
    t = await play("völlig falsch xyz", 0);
    check("Falsch bei 0 Punkten: bleibt 0", Number(t.r.points) === 0 && t.sp === 0, JSON.stringify(t));

    // 6,5 steht über 6
    await q("update public.players set song_points = 6 where lobby_id = $1 and player_id = $2", [lobbyId, host]);
    await q("update public.players set song_points = 6.5 where lobby_id = $1 and is_bot", [lobbyId]);
    const order = await q("select is_bot from public.players where lobby_id = $1 order by song_points desc, tiebreak desc", [lobbyId]);
    check("6,5 liegt vor 6", order[0].is_bot === true);

    // Summen behalten Kommastellen
    await q("update public.players set song_points = 7.25 where lobby_id = $1 and player_id = $2", [lobbyId, host]);
    await q("update public.lobbies set quiz_state = null, phase = 'quiz' where id = $1", [lobbyId]);
    await q("select public._quiz_record_match($1, 'buzzer', now())", [lobbyId]);
    const [{ tot }] = await q("select coalesce(max(total), -1)::float tot from public.quiz_mode_matches where lobby_id = $1", [lobbyId]);
    check("quiz_mode_matches rundet nicht mehr (ohne Konto keine Zeile ist ok)", tot === -1 || tot === 7.25, String(tot));
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    if (lobbyId) {
        await q("delete from public.quiz_mode_matches where lobby_id = $1", [lobbyId]).catch(() => {});
        await q("delete from public.lobbies where id = $1", [lobbyId]).catch(() => {});
    }
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
