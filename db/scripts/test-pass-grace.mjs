#!/usr/bin/env node
/**
 * Testet Migration 091 (Schutzzeit beim Weitergeben) in einer Transaktion, die am Ende zurückgerollt wird.
 * Aufruf: node db/scripts/test-pass-grace.mjs
 */
import { readFileSync } from "node:fs";
import pg from "pg";

const env = Object.fromEntries(
    readFileSync("db/.env.local", "utf8")
        .split(/\r?\n/)
        .filter((l) => l.includes("=") && !l.startsWith("#"))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1)])
);
const db = new pg.Client({ host: env.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
const q = async (s, p = []) => (await db.query(s, p)).rows;
let failed = 0;
const check = (n, ok, d = "") => {
    console.log(`${ok ? "✅" : "❌"} ${n}${d ? "  – " + d : ""}`);
    if (!ok) failed++;
};

try {
    await q("begin");
    const [l] = await q(
        `insert into lobbies (code, host_player_id, phase, round_speed, round_number, topic_selected, run_started_at)
         values ('ZQ9X', gen_random_uuid(), 'running', 'normal', 1, 'Deutschrap aktuell', now()) returning id`
    );
    const ids = [];
    for (let i = 0; i < 4; i++) {
        const [p] = await q(
            "insert into players (lobby_id, player_id, name, seat_index, is_alive, status) values ($1, gen_random_uuid(), $2, $3, true, 'active') returning player_id",
            [l.id, `P${i}`, i]
        );
        ids.push(p.player_id);
    }
    const secLeft = async () => Number((await q("select extract(epoch from explode_at - now()) s, last_grace_sec g, grace_count c from lobbies where id = $1", [l.id]))[0].s);
    const state = async () => (await q("select last_grace_sec g, grace_count c, holder_player_id h from lobbies where id = $1", [l.id]))[0];

    // 1) Weitergabe 0,5 s vor dem Platzen -> Empfänger hat 6 s (Standard)
    await q("update lobbies set holder_player_id = $2, explode_at = now() + interval '500 ms', round_bonus_used = 99 where id = $1", [l.id, ids[0]]);
    await q("select rpc_pass_potato('ZQ9X', $1)", [ids[0]]);
    let s = await secLeft();
    let st = await state();
    check("Letzte Sekunde: Empfänger bekommt 6 s Schutzzeit", s > 5.8 && s <= 6.05 && Number(st.g) === 6 && st.c === 1, `${s.toFixed(2)} s, g=${st.g}, c=${st.c}`);
    check("Kumpir ist beim Nächsten", st.h === ids[1]);

    // 2) gleich nochmal knapp -> 5 s (eine Sekunde weniger)
    await q("update lobbies set explode_at = now() + interval '300 ms' where id = $1", [l.id]);
    await q("select rpc_pass_potato('ZQ9X', $1)", [ids[1]]);
    s = await secLeft();
    check("Zweite Schutzzeit im selben Zug: 5 s", s > 4.8 && s <= 5.05, `${s.toFixed(2)} s`);

    // 3) Untergrenze 4 s
    for (const who of [ids[2], ids[3]]) {
        await q("update lobbies set explode_at = now() + interval '200 ms' where id = $1", [l.id]);
        await q("select rpc_pass_potato('ZQ9X', $1)", [who]);
    }
    s = await secLeft();
    check("Schutzzeit fällt nie unter 4 s", s > 3.8 && s <= 4.05, `${s.toFixed(2)} s`);

    // 4) Genug Restzeit -> keine Schutzzeit, Restzeit bleibt
    await q("update lobbies set explode_at = now() + interval '15 s' where id = $1", [l.id]);
    await q("select rpc_pass_potato('ZQ9X', $1)", [ids[0]]);
    s = await secLeft();
    st = await state();
    check("Mit genug Restzeit greift sie nicht", s > 14.8 && Number(st.g) === 0, `${s.toFixed(2)} s, g=${st.g}`);

    // 5) Neuer Zug (jemand platzt) -> Zähler zurück
    await q("update lobbies set round_number = round_number + 1 where id = $1", [l.id]);
    st = await state();
    check("Neuer Zug: Schutzzeit wieder voll", st.c === 0, `c=${st.c}`);

    // 6) Blitz und Casual
    await q("update lobbies set round_speed = 'fast', explode_at = now() + interval '100 ms' where id = $1", [l.id]);
    const h = (await state()).h;
    await q("select rpc_pass_potato('ZQ9X', $1)", [h]);
    s = await secLeft();
    check("Blitz: 5 s", s > 4.8 && s <= 5.05, `${s.toFixed(2)} s`);
    await q("update lobbies set round_speed = 'calm', grace_count = 0, explode_at = now() + interval '100 ms' where id = $1", [l.id]);
    await q("select rpc_pass_potato('ZQ9X', $1)", [(await state()).h]);
    s = await secLeft();
    check("Casual: 7 s", s > 6.8 && s <= 7.05, `${s.toFixed(2)} s`);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    await q("rollback").catch(() => {});
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden (alles zurückgerollt).");
process.exit(failed ? 1 : 0);
