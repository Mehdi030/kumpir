#!/usr/bin/env node
/**
 * Testet Migration 115: Lebenszeit-Siege zählen JEDE gewonnene Runde (auch Zwischenrunden eines Matches),
 * in den Quiz-Modi gewinnt der Punktbeste, in Teams das Siegerteam. Läuft in EINER Transaktion, am Ende
 * zurückgerollt – nichts bleibt in der Datenbank.
 * Aufruf: node db/scripts/test-wins.mjs
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import pg from "pg";
import { createTestUser } from "./_test-users.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.trim() && !l.trim().startsWith("#") && l.includes("="))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)]),
);
const client = new pg.Client({
    host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false },
});
let failed = 0;
const check = (name, ok, detail = "") => {
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? "  – " + detail : ""}`);
    if (!ok) failed++;
};
await client.connect();
const q = async (sql, p) => (await client.query(sql, p)).rows;
const wins = async (uid) => Number((await q("select coalesce(max(wins),0) w from public.player_lifetime_stats where user_id = $1", [uid]))[0].w);
const games = async (uid) => Number((await q("select coalesce(max(games_played),0) g from public.player_lifetime_stats where user_id = $1", [uid]))[0].g);
const has = async (uid, code) => (await q("select 1 from public.player_achievements where user_id = $1 and achievement_code = $2", [uid, code])).length > 0;

try {
    await q("begin");
    const uA = await createTestUser(q, "wintestA");
    const uB = await createTestUser(q, "wintestB");
    const A = randomUUID(), B = randomUUID();

    const mkLobby = async (code, mode, total) => {
        const [l] = await q("insert into public.lobbies (code, host_player_id, phase, game_mode, series_total, series_index) values ($1, $2, 'running', $3, $4, 1) returning id", [code, A, mode, total]);
        await q(
            `insert into public.players (lobby_id, player_id, name, user_id, status, is_alive, song_points, is_bot, last_seen_at, seat_index) values
             ($1, $2, 'WinA', $4, 'active', true, 0, false, now(), 0), ($1, $3, 'WinB', $5, 'active', true, 0, false, now(), 1)`,
            [l.id, A, B, uA, uB],
        );
        return l.id;
    };

    // ---- 1) Original, Match über 2 Runden: A gewinnt Runde 1, B gewinnt Runde 2
    const L1 = await mkLobby("ZW01", "original", 2);
    await q("update public.lobbies set holder_player_id = $2 where id = $1", [L1, B]); // Halter beim Knall = der Verlierer
    await q("update public.players set is_alive = false, eliminated_at_round = 1 where lobby_id = $1 and player_id = $2", [L1, B]);
    await q("select public._finish_round($1)", [L1]);
    check("Runde 1 (Zwischenrunde): A hat 1 Sieg", (await wins(uA)) === 1, `A=${await wins(uA)} B=${await wins(uB)}`);
    check("Runde 1: B hat 0 Siege", (await wins(uB)) === 0);
    check("Runde 1: beide haben 1 Spiel", (await games(uA)) === 1 && (await games(uB)) === 1);
    check("Erfolg Erstgeborener für A, nicht für B", (await has(uA, "first_win")) && !(await has(uB, "first_win")));

    await q("update public.lobbies set phase = 'running', series_index = 2 where id = $1", [L1]);
    await q("update public.players set is_alive = (player_id = $2), eliminated_at_round = case when player_id = $2 then null else 1 end where lobby_id = $1", [L1, B]);
    await q("update public.lobbies set holder_player_id = $2 where id = $1", [L1, A]);
    await q("select public._finish_round($1)", [L1]);
    check("Runde 2 (letzte): B hat 1 Sieg, A weiter 1", (await wins(uB)) === 1 && (await wins(uA)) === 1, `A=${await wins(uA)} B=${await wins(uB)}`);
    check("Beide haben 2 Spiele (kein Doppelzählen)", (await games(uA)) === 2 && (await games(uB)) === 2, `A=${await games(uA)} B=${await games(uB)}`);

    // ---- 2) Quiz-Modus: alle leben, B hat mehr Punkte -> B gewinnt
    const L2 = await mkLobby("ZW02", "buzzer", 1);
    await q("update public.lobbies set phase = 'quiz', quiz_state = 'reveal' where id = $1", [L2]);
    await q("update public.players set song_points = case when player_id = $2 then 7 else 3 end where lobby_id = $1", [L2, B]);
    await q("select public._quiz_finish($1)", [L2]);
    const [ph] = await q("select phase, quiz_state, holder_player_id from public.lobbies where id = $1", [L2]);
    check("Quiz endet mit phase finished", ph.phase === "finished" && ph.quiz_state === null);
    check("Quiz: Punktbester (B) ist Halter/Sieger", ph.holder_player_id === B);
    check("Quiz: B bekommt den Lebenszeit-Sieg, A nicht", (await wins(uB)) === 2 && (await wins(uA)) === 1, `A=${await wins(uA)} B=${await wins(uB)}`);

    // ---- 3) Nur 1 Mensch -> keine Wertung (Übungsspiel)
    const L4 = await mkLobby("ZW04", "original", 1);
    await q("update public.players set is_bot = true, user_id = null where lobby_id = $1 and player_id = $2", [L4, B]);
    const before = await wins(uA);
    await q("update public.players set is_alive = (player_id = $2) where lobby_id = $1", [L4, A]);
    await q("select public._finish_round($1)", [L4]);
    check("Übungsspiel (1 Mensch): keine Lebenszeit-Wertung", (await wins(uA)) === before, `vorher ${before}, nachher ${await wins(uA)}`);
} catch (e) {
    console.error("❌ Fehler:", e.message);
    failed++;
} finally {
    await q("rollback");
    await client.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
