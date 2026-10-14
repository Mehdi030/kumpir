#!/usr/bin/env node
// Alle Spielmodi mit Bots durchspielen und Regeln prüfen (Wunsch Mehdi 2026-10-13: "teste alle Features").
// Jedes Szenario legt eine eigene Lobby an, wartet bis zum Ende (Server-Takt + Bot-Takt laufen per Cron) und
// prüft: Spiel endet, keine hängende Phase, Wertung vollständig, Quiz-Zustand sauber.
// Aufruf: node db/scripts/test-modes.mjs [Filter]   z. B. "duel" oder "series"
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
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const filter = process.argv[2] || "";

const newDb = async () => {
    const c = new pg.Client({
        host: env.SUPABASE_DB_HOST, port: Number(env.SUPABASE_DB_PORT || 5432), database: env.SUPABASE_DB_NAME || "postgres",
        user: env.SUPABASE_DB_USER || "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false },
    });
    await c.connect();
    return c;
};

const SCENARIOS = [
    { name: "original", mode: "original", players: 4 },
    { name: "original (2)", mode: "original", players: 2 },
    { name: "buzzer", mode: "buzzer", players: 4, quiz: true, target: 10 },
    { name: "buzzer (2)", mode: "buzzer", players: 2, quiz: true, target: 10 },
    { name: "buzzer (12 Spieler)", mode: "buzzer", players: 12, quiz: true, target: 10 },
    { name: "year", mode: "year", players: 4, quiz: true },
    { name: "year (2)", mode: "year", players: 2, quiz: true },
    { name: "year (12 Spieler)", mode: "year", players: 12, quiz: true },
    { name: "series buzzer x3", mode: "buzzer", players: 4, quiz: true, target: 10, series: 3 },
    { name: "series year x3", mode: "year", players: 4, quiz: true, series: 3 },
    { name: "series original x3", mode: "original", players: 4, series: 3 },
    { name: "leave mid buzzer", mode: "buzzer", players: 4, quiz: true, target: 10, leaveAfter: 2 },
    { name: "leave mid year", mode: "year", players: 4, quiz: true, leaveAfter: 2 },
    { name: "leave mid original", mode: "original", players: 4, leaveAfter: 1 },
    { name: "rematch buzzer", mode: "buzzer", players: 3, quiz: true, target: 10, rematch: true },
    { name: "rematch year", mode: "year", players: 3, quiz: true, rematch: true },
].filter((s) => s.name.includes(filter));

async function run(sc) {
    const db = await newDb();
    const q = async (sql, args = []) => (await db.query(sql, args)).rows;
    const problems = [];
    const note = (m) => problems.push(m);
    const t0 = Date.now();
    let code, id;
    try {
        const [{ code: c, host_player_id: host }] = await q("select * from public.rpc_create_lobby($1, 'private', 12, 60)", ["T" + sc.name.slice(0, 6)]);
        code = c;
        [{ id }] = await q("select id from public.lobbies where code = $1", [code]);
        for (let i = 1; i < sc.players; i++) await q("select public.rpc_add_bot($1, $2, $3, $4::smallint)", [id, host, `Bot ${i}`, (i % 3) + 1]);
        // Beim Verlassen-Test bleibt der Host ein Mensch (letzter Mensch weg = Lobby schließt sich, das ist Absicht)
        if (sc.leaveAfter) await q("update public.players set bot_skill = 2, last_seen_at = now() + interval '2 hours' where player_id = $1", [host]);
        else await q("update public.players set is_bot = true, bot_skill = 2 where player_id = $1", [host]);
        // Testlobbys dürfen nicht vom Aufräumer (3 Min ohne Mensch) gelöscht werden
        await q("update public.lobbies set created_at = now() + interval '2 hours' where id = $1", [id]);
        await q(
            `update public.lobbies set game_mode = $2, topic_selected = 'Deutschrap aktuell', phase = 'countdown', countdown_ends_at = now(),
               series_index = 1, series_total = $3 where id = $1`,
            [id, sc.mode, sc.series ?? 1],
        );
        await q("select public.rpc_advance_from_countdown($1)", [id]);

        let last = "", lastChange = Date.now(), left = 0, rematched = false, sawSummary = false, qSeen = 0;
        const maxSec = (sc.series ?? 1) * 330 + (sc.rematch ? 330 : 0) + 120;
        for (;;) {
            const [l] = await q("select phase, quiz_state, quiz_index, quiz_total, series_index, round_number, game_mode from public.lobbies where id = $1", [id]);
            if (!l) { note("Lobby wurde mitten im Spiel gelöscht"); break; }
            const key = `${l.phase}/${l.quiz_state}/${l.quiz_index}/${l.series_index}/${l.round_number}`;
            if (key !== last) { last = key; lastChange = Date.now(); if (l.quiz_state === "question") qSeen++; }
            if (l.phase === "set_summary") sawSummary = true;
            if (Date.now() - lastChange > 75000) { note(`hängt seit 75 s in ${key}`); break; }
            if (Date.now() - t0 > maxSec * 1000) { note("Zeitüberschreitung"); break; }

            // Spieler verlässt mitten im Spiel
            if (sc.leaveAfter && !left && ((sc.quiz && l.quiz_index >= sc.leaveAfter) || (!sc.quiz && l.round_number >= sc.leaveAfter))) {
                if (sc.leavePicker && !(l.quiz_state === "pick" && (await q("select quiz_picker p from public.lobbies where id = $1", [id]))[0]?.p !== host)) { await wait(400); continue; }
                const target = sc.leavePicker
                    ? (await q("select quiz_picker p from public.lobbies where id = $1", [id]))[0]?.p
                    : (await q("select player_id p from public.players where lobby_id = $1 and status = 'active' and player_id <> $2 and is_alive order by seat_index desc limit 1", [id, host]))[0]?.p;
                if (target) {
                    try { await q("select public.rpc_leave_lobby($1, $2)", [id, target]); left = 1; } catch (e) { note("rpc_leave_lobby: " + e.message); left = 1; }
                }
            }
            if (l.phase === "finished") {
                if (sc.rematch && !rematched) {
                    rematched = true;
                    try { await q("select public.rpc_rematch($1, $2)", [code, host]); } catch (e) { note("rpc_rematch: " + e.message); break; }
                    await wait(1000);
                    continue;
                }
                break;
            }
            await wait(600);
        }

        // ---- Prüfungen
        const [l] = await q("select phase, quiz_state, quiz_index, quiz_total, series_total from public.lobbies where id = $1", [id]);
        if (l) {
            if (l.phase !== "finished") note(`Endphase ist ${l.phase}, nicht finished`);
            if (sc.quiz && l.quiz_state !== null) note(`quiz_state nach Ende nicht leer: ${l.quiz_state}`);
            if (sc.quiz && qSeen < (sc.mode === "year" ? l.quiz_total : 3)) note(`nur ${qSeen} Fragen gesehen`);
            const players = await q("select count(*)::int n from public.players where lobby_id = $1 and status = 'active'", [id]);
            const res = await q("select set_index, count(*)::int n, sum(song_points)::numeric pts, min(place)::int pmin, max(place)::int pmax, count(distinct place)::int pd from public.series_results where lobby_id = $1 group by set_index order by set_index", [id]);
            const expectSets = sc.series ?? 1;
            const expectRows = expectSets; // bei Rematch überschreibt die zweite Partie die Zeile derselben Runde (gewollt)
            if (res.length < expectRows) note(`nur ${res.length} von ${expectRows} Runden in series_results`);
            for (const r of res) {
                if (r.pd !== r.n) note(`Runde ${r.set_index}: doppelte Plätze (${r.pd} verschieden bei ${r.n} Spielern)`);
                if (r.pmin !== 1) note(`Runde ${r.set_index}: kein Platz 1`);
                if (!(Number(r.pts) >= 0)) note(`Runde ${r.set_index}: negative Punkte`);
            }
            if (sc.series > 1 && !sawSummary) note("Zwischenstand (set_summary) nie gesehen");
            if (sc.target && !sc.leaveAfter) {
                const m = await q("select max(song_points)::numeric mx from public.series_results where lobby_id = $1 and set_index = (select max(set_index) from public.series_results where lobby_id = $1)", [id]);
                const [ql] = await q("select quiz_total, quiz_index from public.lobbies where id = $1", [id]);
                if (!(Number(m[0].mx) >= sc.target) && ql.quiz_index < ql.quiz_total) note(`Buzzer endete ohne Ziel (${m[0].mx} Punkte nach ${ql.quiz_index} Songs)`);
                if (Number(m[0].mx) < sc.target) note(`Hinweis: Ziel ${sc.target} nicht erreicht (max ${m[0].mx}) – Songlimit`);
            }
            if (sc.mode === "year" && l.quiz_total !== 8) note(`Jahr raten hat quiz_total ${l.quiz_total} statt 8`);
            if (sc.quiz && !sc.leaveAfter && res.length) {
                const tot = res.reduce((a, r) => a + Number(r.pts), 0);
                if (tot <= 0) note("alle Quiz-Punkte 0 – niemand hat je gepunktet");
            }
            void players;
        }
    } catch (e) {
        note("Fehler: " + e.message);
    } finally {
        if (id) await db.query("delete from public.lobbies where id = $1", [id]).catch(() => {});
        await db.end().catch(() => {});
    }
    const sec = Math.round((Date.now() - t0) / 1000);
    console.log(`${problems.length ? "❌" : "✅"} ${sc.name.padEnd(26)} ${String(sec).padStart(4)} s${problems.length ? "  → " + problems.join("; ") : ""}`);
    return problems.length === 0;
}

// höchstens 4 Szenarien gleichzeitig (Verbindungs-Limit)
const queue = [...SCENARIOS];
const results = [];
await Promise.all(
    Array.from({ length: 4 }, async () => {
        while (queue.length) results.push(await run(queue.shift()));
    }),
);
const fails = results.filter((r) => !r).length;
console.log(fails ? `\n${fails} von ${results.length} Szenarien mit Problemen` : `\nAlle ${results.length} Szenarien in Ordnung`);
process.exit(fails ? 1 : 0);
