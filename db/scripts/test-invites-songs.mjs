#!/usr/bin/env node
/**
 * Testet Migration 092 in EINER Transaktion, die zurückgerollt wird:
 * Lobby-Einladungen, "Schon gesagt" zeigt den richtigen Song, keine Song-Wiederholung im Match,
 * Bots raten meist den Künstler.
 * Aufruf: node db/scripts/test-invites-songs.mjs
 */
import { readFileSync } from "node:fs";
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
    const a = await createTestUser(q, "invA");
    const b = await createTestUser(q, "invB");
    const x = await createTestUser(q, "invX");
    await q("insert into friendships (user_id, friend_user_id, status, accepted_at) values ($1,$2,'accepted',now()), ($2,$1,'accepted',now())", [a, b]);

    const [l] = await q("insert into lobbies (code, host_player_id, phase) values ('QV7K', gen_random_uuid(), 'waiting') returning id");
    await q("insert into players (lobby_id, player_id, name, seat_index, user_id, status) values ($1, gen_random_uuid(), 'A', 0, $2, 'active')", [l.id, a]);

    // ---- Einladungen
    let r = await as(a, "select rpc_invite_friend('QV7K', $1)", [b]);
    check("Freund einladen klappt", !r.error, r.error);
    r = await as(a, "select rpc_invite_friend('QV7K', $1)", [x]);
    check("Fremde (keine Freunde) einladen wird abgelehnt", !!r.error, r.error);
    r = await as(x, "select rpc_invite_friend('QV7K', $1)", [b]);
    check("Wer nicht in der Lobby ist, kann nicht einladen", !!r.error, r.error);
    r = await as(b, "select rpc_my_invites() j");
    const inv = r.rows?.[0]?.j ?? [];
    check("Eingeladener sieht die Einladung mit Code und Namen", inv.length === 1 && inv[0].lobbyCode === "QV7K" && !!inv[0].fromName, JSON.stringify(inv));
    r = await as(x, "select rpc_my_invites() j");
    check("Andere sehen sie nicht", (r.rows?.[0]?.j ?? []).length === 0);
    r = await as(x, "select rpc_respond_invite($1, true) c", [inv[0]?.id]);
    check("Fremde können sie nicht annehmen", !r.error && r.rows[0].c === null);
    r = await as(b, "select rpc_respond_invite($1, true) c", [inv[0]?.id]);
    check("Annehmen liefert den Lobby-Code", r.rows?.[0]?.c === "QV7K", JSON.stringify(r));
    r = await as(b, "select rpc_my_invites() j");
    check("Danach ist sie weg", (r.rows?.[0]?.j ?? []).length === 0);
    r = await as(null, "select * from lobby_invites");
    check("Tabelle nicht direkt lesbar", !!r.error);

    // ---- Schon gesagt = richtiger Song
    const [song] = await q("select sp.id, sp.title, sp.artist from song_pool sp join topic_pool tp on tp.id = sp.topic_pool_id where tp.text = 'Deutschrap aktuell' limit 1");
    const pids = [];
    for (let i = 0; i < 3; i++) {
        const [p] = await q("insert into players (lobby_id, player_id, name, seat_index, is_alive, status, is_bot) values ($1, gen_random_uuid(), $2, $3, true, 'active', true) returning player_id", [l.id, `B${i}`, i + 1]);
        pids.push(p.player_id);
    }
    await q(
        "update lobbies set phase='running', topic_selected='Deutschrap aktuell', holder_player_id=$2, holder_since=now(), explode_at=now()+interval '20 s', current_song_id=$3, used_answers='{}', round_number=1 where id=$1",
        [l.id, pids[0], song.id]
    );
    await q("select rpc_attempt_pass('QV7K', $1, $2)", [pids[0], song.artist.split(/,|&/)[0].trim()]);
    const [la] = await q("select used_answers from lobbies where id = $1", [l.id]);
    const shown = la.used_answers[la.used_answers.length - 1];
    check("Liste zeigt den richtigen Song statt der Eingabe", shown === `${song.title} – ${song.artist}`, shown);

    // ---- Keine Wiederholung im Match
    await q("update lobbies set phase='countdown', series_index=2, series_total=3, used_song_ids=array[$2::uuid], countdown_ends_at=now() where id=$1", [l.id, song.id]);
    await q("select rpc_advance_from_countdown($1)", [l.id]);
    let [u] = await q("select used_song_ids from lobbies where id=$1", [l.id]);
    check("Runde 2 behält die gespielten Songs", u.used_song_ids.includes(song.id) && u.used_song_ids.length >= 2, `${u.used_song_ids.length} Songs`);
    await q("update lobbies set phase='countdown', series_index=1, countdown_ends_at=now() where id=$1", [l.id]);
    await q("select rpc_advance_from_countdown($1)", [l.id]);
    [u] = await q("select used_song_ids from lobbies where id=$1", [l.id]);
    check("Neues Match fängt frisch an", u.used_song_ids.length === 1, `${u.used_song_ids.length} Songs`);

    // ---- Bots: Anteil Künstler (gleiche Formel wie _bot_tick, 2000 Würfe)
    const [d] = await q(`select avg(case when (abs(hashtext('a' || g::text)) % 1000) / 1000.0 < 0.75 then 1 else 0 end) share from generate_series(1, 2000) g`);
    check("Bots (Mittel) nennen ~75 % den Künstler", Number(d.share) > 0.7 && Number(d.share) < 0.8, `${Math.round(Number(d.share) * 100)} %`);
    const def = (await q("select pg_get_functiondef('public._bot_tick'::regproc) d"))[0].d;
    check("Bot-Chancen 80/75/70 % eingebaut", def.includes("when 1 then 0.80 when 3 then 0.70 else 0.75"));
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await c.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
