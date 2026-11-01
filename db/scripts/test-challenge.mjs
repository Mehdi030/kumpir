#!/usr/bin/env node
// Prüft "Freunde herausfordern" (Migration 139) mit Test-Lobbys (werden am Ende gelöscht):
// beendetes Quiz-Spiel -> Herausforderung -> Solo-Lobby des Freundes verknüpfen -> Ergebnis speichern und vergleichen.
// Aufruf: node db/scripts/test-challenge.mjs
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
const ids = [];
let code = null;
const mk = async (mode, points, phase = "finished") => {
    const [{ code: c, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Herausforderer', 'private', 12, 60)");
    const [{ id }] = await q("select id from public.lobbies where code = $1", [c]);
    ids.push(id);
    await q("select public.rpc_add_bot($1, $2, 'Bot 1', 2::smallint)", [id, host]);
    await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = $2, phase = $3, series_index = 1, series_total = 1, run_started_at = now() where id = $1", [id, mode, phase]);
    await q("update public.players set song_points = $3 where lobby_id = $1 and player_id = $2", [id, host, points]);
    return { id, host };
};
try {
    const a = await mk("buzzer", 17);
    [code] = (await q("select public.rpc_challenge_create($1, $2) c", [a.id, a.host])).map((r) => r.c);
    check("Herausforderung angelegt (6-stelliger Code)", /^[0-9A-F]{6}$/.test(code), code);
    const ch = (await q("select public.get_challenge($1) c", [code.toLowerCase()]))[0].c;
    check("get_challenge liefert Punktzahl und Modus", ch.score === 17 && ch.mode === "buzzer" && ch.creator === "Herausforderer" && ch.bots === 1, JSON.stringify(ch).slice(0, 160));
    check("Unbekannter Code liefert nichts", (await q("select public.get_challenge('ZZZZZZ') c"))[0].c === null);

    // Original-Tisch kann nicht herausfordern
    const o = await mk("original", 3);
    let err = "";
    try { await q("select public.rpc_challenge_create($1, $2)", [o.id, o.host]); } catch (e) { err = e.message; }
    check("Original-Tisch: keine Herausforderung", /challenge_bad_mode/.test(err), err);
    // Laufendes Spiel: nicht möglich
    const r = await mk("buzzer", 5, "quiz");
    err = "";
    try { await q("select public.rpc_challenge_create($1, $2)", [r.id, r.host]); } catch (e) { err = e.message; }
    check("Laufendes Spiel: keine Herausforderung", /challenge_not_finished/.test(err), err);

    // Freund spielt mit höherer Punktzahl
    const f = await mk("buzzer", 23, "lobby");
    await q("select public.rpc_challenge_attach($1, $2, $3)", [code, f.id, f.host]);
    const [{ challenge_code }] = await q("select challenge_code from public.lobbies where id = $1", [f.id]);
    check("Solo-Lobby ist verknüpft", challenge_code === code);
    err = "";
    try { await q("select public.rpc_challenge_attach($1, $2, $3)", [code, f.id, f.host]); } catch (e) { err = e.message; }
    check("Doppeltes Verknüpfen abgelehnt", /challenge_attach_failed/.test(err), err);
    const early = (await q("select public.rpc_challenge_submit($1, $2) r", [f.id, f.host]))[0].r;
    check("Vor dem Ende kein Ergebnis", early === null);
    await q("update public.lobbies set phase = 'finished' where id = $1", [f.id]);
    const res = (await q("select public.rpc_challenge_submit($1, $2) r", [f.id, f.host]))[0].r;
    check("Freund schlägt die Punktzahl", res?.won === true && res.score === 23 && res.target === 17 && res.rank === 1, JSON.stringify(res));
    const again = (await q("select public.rpc_challenge_submit($1, $2) r", [f.id, f.host]))[0].r;
    check("Zweites Speichern ändert nichts", again?.score === 23);
    const n = (await q("select count(*)::int n from public.challenge_results where code = $1", [code]))[0].n;
    check("Genau ein Ergebnis gespeichert", n === 1);

    // Verlierer
    const g = await mk("buzzer", 4, "lobby");
    await q("select public.rpc_challenge_attach($1, $2, $3)", [code, g.id, g.host]);
    await q("update public.lobbies set phase = 'finished' where id = $1", [g.id]);
    const lose = (await q("select public.rpc_challenge_submit($1, $2) r", [g.id, g.host]))[0].r;
    check("Zu wenig Punkte = verloren, Platz 2", lose?.won === false && lose.rank === 2, JSON.stringify(lose));
    const ch2 = (await q("select public.get_challenge($1) c", [code]))[0].c;
    check("Bestenliste der Herausforderung sortiert", ch2.results.length === 2 && ch2.results[0].score === 23);

    // Sicherheit: Tabellen gesperrt, Hilfsfunktion nicht aufrufbar
    const [{ t }] = await q("select has_table_privilege('anon', 'public.challenges', 'select') t");
    const [{ f: fn }] = await q("select has_function_privilege('anon', 'public._challenge_score(uuid, uuid)', 'execute') f");
    check("Tabellen und _challenge_score von außen gesperrt", t === false && fn === false);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    if (code) await q("delete from public.challenges where code = $1", [code]).catch(() => {});
    for (const id of ids) await q("delete from public.lobbies where id = $1", [id]).catch(() => {});
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
