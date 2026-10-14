#!/usr/bin/env node
// Prüft den Monats-Entscheid in "Jahr raten" (Migration 126) mit einer echten Test-Lobby (wird am Ende gelöscht):
// zwei Bots tippen dasselbe Jahr -> Zustand "month" nur für diese zwei -> Monate tippen -> Auflösung mit +1 Bonus.
// Aufruf: node db/scripts/test-year-tiebreak.mjs
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
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
const check = (name, ok, detail = "") => {
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? "  – " + detail : ""}`);
    if (!ok) failed++;
};

let id = null;
try {
    const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Tiebreak', 'private', 12, 60)");
    [{ id }] = await q("select id from public.lobbies where code = $1", [code]);
    for (let i = 1; i < 4; i++) await q("select public.rpc_add_bot($1, $2, $3, $4::smallint)", [id, host, `Bot ${i}`, 2]);
    await q("update public.players set is_bot = true, bot_skill = 2 where player_id = $1", [host]);
    await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = 'year', topic_selected = 'Deutschrap aktuell', phase = 'countdown', countdown_ends_at = now(), series_index = 1, series_total = 1 where id = $1", [id]);
    await q("select public.rpc_advance_from_countdown($1)", [id]);

    // sofort handeln, bevor die Bots tippen (frühestens nach ~3 s)
    let st = null;
    for (let i = 0; i < 40; i++) {
        [st] = await q("select quiz_state, quiz_seq from public.lobbies where id = $1", [id]);
        if (st?.quiz_state === "question") break;
        await wait(250);
    }
    check("Frage läuft", st?.quiz_state === "question");
    // Monat für den Test fest setzen (so hängt der Test nicht davon ab, ob der Zufallssong schon einen Monat hat)
    await q("update public.quiz_secret set month = 7 where lobby_id = $1", [id]);
    const [sec] = await q("select year, month from public.quiz_secret where lobby_id = $1", [id]);
    check("Song hat Jahr und Monat", !!sec?.year && !!sec?.month, JSON.stringify(sec));
    const bots = await q("select player_id from public.players where lobby_id = $1 and status = 'active' order by seat_index", [id]);
    const [a, b, c, d] = bots.map((r) => r.player_id);
    const ins = (p, num) => q("insert into public.quiz_answers (lobby_id, seq, player_id, answer, num, correct, points, tries, answered_at) values ($1, $2, $3, $4, $5, false, 0, 1, now()) on conflict (lobby_id, seq, player_id) do update set num = excluded.num", [id, st.quiz_seq, p, String(num), num]);
    await ins(a, sec.year); // genau richtig
    await ins(b, sec.year); // genau richtig -> Gleichstand
    await ins(c, sec.year + 4);
    await ins(d, sec.year - 6);
    await q("update public.lobbies set quiz_ends_at = now() - interval '1 second' where id = $1", [id]);
    await q("select public._quiz_tick($1)", [id]);
    let [l] = await q("select quiz_state, quiz_options from public.lobbies where id = $1", [id]);
    check("Gleichstand -> Monats-Entscheid", l.quiz_state === "month", l.quiz_state);
    const tie = (l.quiz_options?.tie?.players ?? []).slice().sort();
    check("nur die zwei Gleichstehenden dürfen tippen", tie.length === 2 && tie.includes(a) && tie.includes(b), JSON.stringify(tie.length));

    // Nicht-Beteiligter darf nicht
    let err = "";
    try { await q("select public._quiz_do_choose($1, $2, '3')", [id, c]); } catch (e) { err = e.message; }
    check("Nicht-Gleichstehende werden abgelehnt", /quiz_not_in_tie/.test(err), err);
    // Falscher Monat
    err = "";
    try { await q("select public._quiz_do_choose($1, $2, '13')", [id, a]); } catch (e) { err = e.message; }
    check("Monat 13 wird abgelehnt", /quiz_bad_month/.test(err), err);

    const near = sec.month; // a trifft genau
    const far = ((sec.month + 4) % 12) + 1; // b liegt weiter weg
    const before = Object.fromEntries((await q("select player_id, song_points from public.players where lobby_id = $1", [id])).map((r) => [r.player_id, Number(r.song_points ?? 0)]));
    await q("select public._quiz_do_choose($1, $2, $3)", [id, a, String(near)]);
    err = "";
    try { await q("select public._quiz_do_choose($1, $2, '5')", [id, a]); } catch (e) { err = e.message; }
    check("zweites Tippen wird abgelehnt", /quiz_already_answered/.test(err), err);
    await q("select public._quiz_do_choose($1, $2, $3)", [id, b, String(far)]);
    await wait(1800);
    await q("select public._quiz_tick($1)", [id]); // falls die 0,8 s noch nicht um waren
    [l] = await q("select quiz_state, quiz_reveal from public.lobbies where id = $1", [id]);
    check("danach Auflösung", l.quiz_state === "reveal", l.quiz_state);
    const winners = l.quiz_reveal?.tie?.winners ?? [];
    check("nächster Monat gewinnt", winners.length === 1 && winners[0] === a, JSON.stringify(winners));
    check("echter Monat steht in der Auflösung", l.quiz_reveal?.month === sec.month, String(l.quiz_reveal?.month));
    const after = Object.fromEntries((await q("select player_id, song_points from public.players where lobby_id = $1", [id])).map((r) => [r.player_id, Number(r.song_points ?? 0)]));
    check("Sieger: 5 (Jahr) + 1 Bonus", after[a] - before[a] === 6, `${before[a]} -> ${after[a]}`);
    check("Verlierer des Entscheids: nur 5", after[b] - before[b] === 5, `${before[b]} -> ${after[b]}`);
    check("andere Spieler unverändert", after[c] - before[c] === 1 + 0 && after[d] - before[d] === 0, `c ${before[c]} -> ${after[c]}, d ${before[d]} -> ${after[d]}`);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    if (id) await q("delete from public.lobbies where id = $1", [id]).catch(() => {});
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
