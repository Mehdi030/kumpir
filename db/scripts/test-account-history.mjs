#!/usr/bin/env node
/**
 * Testet Migration 076 (Konto-Verlauf/Analyse) in EINER Transaktion, die am Ende
 * zurückgerollt wird – es bleibt nichts in der Datenbank.
 *
 * Ablauf: Lobby mit 2 eingeloggten Menschen + 1 Bot anlegen -> Matchstart (match_id) ->
 * Treffer/Fehlversuch/Explosion simulieren (game_events) -> _finish_round ->
 * account_rounds/account_matches/Achievements/get_my_profile_stats prüfen.
 *
 * Aufruf: node db/scripts/test-account-history.mjs
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import pg from "pg";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.trim() && !l.trim().startsWith("#") && l.includes("="))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)])
);

const client = new pg.Client({
    host: env.SUPABASE_DB_HOST,
    port: Number(env.SUPABASE_DB_PORT || 5432),
    database: env.SUPABASE_DB_NAME || "postgres",
    user: env.SUPABASE_DB_USER || "postgres",
    password: env.SUPABASE_DB_PASSWORD,
    ssl: { rejectUnauthorized: false },
});

let failed = 0;
function check(name, ok, detail = "") {
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? "  – " + detail : ""}`);
    if (!ok) failed++;
}

await client.connect();
const q = async (sql, params) => (await client.query(sql, params)).rows;

try {
    await q("begin");

    const users = await q("select id from public.profiles order by created_at limit 2");
    if (users.length < 2) throw new Error("Für den Test werden 2 Konten (profiles) gebraucht.");
    const [u1, u2] = users.map((u) => u.id);
    const [song] = await q(
        "select sp.id, tp.text from public.song_pool sp join public.topic_pool tp on tp.id = sp.topic_pool_id where tp.is_song_category limit 1"
    );

    const host = randomUUID(), p2 = randomUUID(), bot = randomUUID();
    const [lobby] = await q(
        "insert into public.lobbies (code, host_player_id, phase, series_total, series_index) values ('ZZT1', $1, 'waiting', 1, 1) returning id",
        [host]
    );
    const L = lobby.id;
    await q(
        `insert into public.players (lobby_id, player_id, name, user_id, status, is_alive, song_points, is_bot) values
         ($1, $2, 'TestA', $4, 'active', true, 0, false),
         ($1, $3, 'TestB', $5, 'active', true, 0, false),
         ($1, $6, 'Bot',   null, 'active', true, 0, true)`,
        [L, host, p2, u1, u2, bot]
    );

    // Matchstart
    await q("update public.lobbies set phase = 'topic_vote' where id = $1", [L]);
    const [m] = await q("select match_id from public.lobbies where id = $1", [L]);
    check("Matchstart vergibt match_id", !!m.match_id);

    await q(
        "update public.lobbies set phase = 'running', topic_selected = $2, current_song_id = $3, current_song_started_at = now() - interval '2 seconds', holder_player_id = $4, round_number = 1 where id = $1",
        [L, song.text, song.id, host]
    );

    // Spieler A: 1 Fehlversuch, dann Titel (combo 1); Spieler B: Interpret; Bot explodiert
    await q("update public.players set last_wrong_guess_at = now() where lobby_id = $1 and player_id = $2", [L, host]);
    await q("update public.players set song_points = song_points + 1, combo = 1 where lobby_id = $1 and player_id = $2", [L, host]);
    await q("update public.players set song_points = song_points + 0.5 where lobby_id = $1 and player_id = $2", [L, p2]);
    await q("update public.lobbies set holder_player_id = $2 where id = $1", [L, bot]);
    await q("update public.players set is_alive = false, eliminated_at_round = 1 where lobby_id = $1 and player_id = $2", [L, bot]);
    // Rücksetzungen dürfen KEINE Ereignisse erzeugen
    await q("update public.players set last_seen_at = now() where lobby_id = $1", [L]);

    const ev = await q("select kind, player_id, ms, playlist, match_id from public.game_events where lobby_id = $1 order by id", [L]);
    check("4 Spielereignisse protokolliert", ev.length === 4, ev.map((e) => e.kind).join(","));
    check("Ereignisse haben match_id und Playlist", ev.every((e) => e.match_id === m.match_id && e.playlist === song.text));
    const title = ev.find((e) => e.kind === "title");
    check("Antwortzeit plausibel (~2 s)", title && title.ms >= 1500 && title.ms < 10000, `${title?.ms} ms`);

    // Runde beenden (Spieler B scheidet aus, A gewinnt)
    await q("update public.players set is_alive = false, eliminated_at_round = 2 where lobby_id = $1 and player_id = $2", [L, p2]);
    await q("select public._finish_round($1)", [L]);

    const [ph] = await q("select phase from public.lobbies where id = $1", [L]);
    check("Spielablauf unverändert: Phase 'finished'", ph.phase === "finished");
    const sr = await q("select count(*)::int n from public.series_results where lobby_id = $1", [L]);
    check("series_results wie bisher (3 Spieler)", sr[0].n === 3);

    const rounds = await q("select user_id, place, title_hits, artist_hits, wrong_guesses, ranked, playlist from public.account_rounds where match_id = $1 order by place", [m.match_id]);
    check("account_rounds: 2 Konten", rounds.length === 2, JSON.stringify(rounds.map((r) => [r.place, r.title_hits, r.artist_hits, r.wrong_guesses])));
    const ra = rounds.find((r) => r.user_id === u1);
    check("Spieler A: 1 Titel, 1 Fehlversuch, Platz 1, gewertet", ra && ra.title_hits === 1 && ra.wrong_guesses === 1 && ra.place === 1 && ra.ranked);
    const rb = rounds.find((r) => r.user_id === u2);
    check("Spieler B: 1 Interpret", rb && rb.artist_hits === 1);

    const matches = await q("select user_id, place, players_count, humans_count, bots_count, ranked from public.account_matches where match_id = $1", [m.match_id]);
    check("account_matches: 2 Konten mit Match-Platz", matches.length === 2 && matches.some((x) => x.user_id === u1 && x.place === 1), JSON.stringify(matches.map((x) => [x.place, x.players_count, x.humans_count, x.bots_count])));

    const ach = await q("select achievement_code from public.player_achievements where user_id = $1 and lobby_id = $2", [u1, L]);
    check("Achievement 'Ohrwurm' für Spieler A", ach.some((a) => a.achievement_code === "music_first_title"), ach.map((a) => a.achievement_code).join(","));

    // Profil-Statistik als eingeloggter Spieler A
    await q("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: u1, role: "authenticated" })]);
    const [st] = await q("select public.get_my_profile_stats() as s");
    const s = st.s;
    check("Profil: Match + Sieg gezählt", s.totals.matches >= 1 && s.totals.matchWins >= 1, JSON.stringify(s.totals));
    check("Profil: Musik-Werte", s.music.titles >= 1 && s.music.wrong >= 1, JSON.stringify(s.music));
    check("Profil: Gegner B sichtbar", s.opponents.length >= 1, JSON.stringify(s.opponents));
    check("Profil: Verlauf enthält das Match", s.recent.length >= 1);
    check("Profil: Monats-Rückblick", s.recap.matches >= 1 && s.recap.titles >= 1, JSON.stringify(s.recap));

    // Nur-1-Mensch-Spiel (Solo) -> nicht gewertet, aber im Verlauf
    const [l2] = await q("insert into public.lobbies (code, host_player_id, phase, series_total, series_index) values ('ZZT2', $1, 'waiting', 1, 1) returning id", [host]);
    await q(
        `insert into public.players (lobby_id, player_id, name, user_id, status, is_alive, song_points, is_bot) values
         ($1, $2, 'TestA', $3, 'active', true, 0, false), ($1, $4, 'Bot', null, 'active', false, 0, true)`,
        [l2.id, host, u1, randomUUID()]
    );
    await q("update public.lobbies set phase = 'topic_vote' where id = $1", [l2.id]);
    await q("update public.lobbies set phase = 'running', topic_selected = $2 where id = $1", [l2.id, song.text]);
    await q("select public._finish_round($1)", [l2.id]);
    const solo = await q("select ranked from public.account_matches am join public.lobbies l on l.match_id = am.match_id where l.id = $1", [l2.id]);
    check("Solo-Match im Verlauf, aber nicht gewertet", solo.length === 1 && solo[0].ranked === false);

    // Admin-Funktionen: Nicht-Admin wird abgewiesen
    const [nonAdmin] = await q("select id from public.profiles where not coalesce(is_platform_admin, false) limit 1");
    await q("savepoint sp_admin");
    await q("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: nonAdmin.id, role: "authenticated" })]);
    let blocked = false;
    try {
        await q("select public.admin_song_stats()");
    } catch (e) {
        blocked = /not_authorized/.test(e.message);
    }
    await q("rollback to savepoint sp_admin");
    check("admin_song_stats für Nicht-Admin gesperrt", blocked);

    const [admin] = await q("select id from public.profiles where coalesce(is_platform_admin, false) limit 1");
    if (admin) {
        await q("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: admin.id, role: "authenticated" })]);
        const [b] = await q("select public.admin_balance_stats(30) as b, public.admin_song_stats(90) as s, public.admin_funnel(30) as f");
        check("Admin-Auswertungen laufen", Array.isArray(b.b.groups) && Array.isArray(b.s) && Array.isArray(b.f), `groups=${b.b.groups.length}`);
    }

    // Funnel: unbekannte Ereignisse werden ignoriert
    await q("select public.log_event('solo_start', 'test-device-123', '{\"dev\":true}'::jsonb)");
    await q("select public.log_event('evil', 'test-device-123', null)");
    const fe = await q("select event from public.funnel_events where anon_id = 'test-device-123'");
    check("log_event: nur erlaubte Ereignisse", fe.length === 1 && fe[0].event === "solo_start");
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await client.end();
}

console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
