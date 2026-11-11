#!/usr/bin/env node
// Prüft den Modus "Hit oder Flop" (Migration 143) mit Test-Lobbys (werden am Ende gelöscht):
// Mindestens 3 Spieler, Rollen reihum, Song-Suche, Wahl (Song / nur Name), Takt, Jury-Entscheidung, Unentschieden, Bots, Ende.
// Aufruf: node db/scripts/test-battle.mjs
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
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
const fails = async (fn) => { try { await fn(); return ""; } catch (e) { return e.message; } };
const ids = [];
const lob = async (id) => (await q("select quiz_state, quiz_index, quiz_total, quiz_options, quiz_reveal, phase from public.lobbies where id = $1", [id]))[0];
const pointsOf = async (id) => Object.fromEntries((await q("select player_id, song_points::float sp from public.players where lobby_id = $1", [id])).map((r) => [r.player_id, r.sp]));
const expire = (id) => q("update public.lobbies set quiz_ends_at = now() - interval '1 second' where id = $1", [id]);
const tick = async (id) => { await expire(id); await q("select public._quiz_tick($1)", [id]); };

try {
    // ---------- 1) drei Menschen ----------
    const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Jury0', 'private', 12, 60)");
    const [{ id }] = await q("select id from public.lobbies where code = $1", [code]);
    ids.push(id);
    const g1 = randomUUID(), g2 = randomUUID();
    await q("select public.rpc_join_lobby($1::text, $2::uuid, 'Gast1'::text, null::uuid)", [code, g1]);
    await q("select public.rpc_join_lobby($1::text, $2::uuid, 'Gast2'::text, null::uuid)", [code, g2]);
    await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = 'battle', series_index = 1, series_total = 1 where id = $1", [id]);
    check("Modus battle wird akzeptiert", (await q("select public.set_lobby_mode($1, $2, 'battle')", [id, host])).length === 1);
    check("Einstellung: Prinzip 'sound' gespeichert", (await q("select public.set_battle_config($1, $2, '{\"criterion\":\"sound\"}'::jsonb)", [id, host])).length === 1);
    check("Einstellung: unbekanntes Prinzip abgelehnt", /battle_bad_config/.test(await fails(() => q("select public.set_battle_config($1, $2, '{\"criterion\":\"x\"}'::jsonb)", [id, host]))));

    // Start mit nur 2 Leuten geht nicht
    await q("update public.players set status = 'left' where lobby_id = $1 and player_id = $2", [id, g2]);
    check("Start mit 2 Leuten abgelehnt", /battle_need_three/.test(await fails(() => q("select public.rpc_begin_topic_vote($1, $2)", [id, host]))));
    await q("update public.players set status = 'active' where lobby_id = $1 and player_id = $2", [id, g2]);

    await q("update public.lobbies set phase = 'quiz' where id = $1", [id]);
    await q("select public._quiz_begin($1)", [id]);
    let l = await lob(id);
    check("Duell 1 startet im Zustand 'pick', 3 Duelle insgesamt", l.quiz_state === "pick" && l.quiz_index === 1 && l.quiz_total === 3, JSON.stringify([l.quiz_state, l.quiz_index, l.quiz_total]));
    let d = l.quiz_options.duel;
    check("Prinzip kommt aus der Einstellung", d.crit === "sound", d.crit);
    check("Jury und die zwei Battle-Teilnehmer sind drei verschiedene Leute", new Set([d.jury, d.a, d.b]).size === 3);
    const roles = [d.jury];
    const battlers = new Map();
    const bump = (k) => battlers.set(k, (battlers.get(k) ?? 0) + 1);

    // Song-Suche
    const found = (await q("select public.rpc_battle_search($1, $2, 'an') r", [code, d.a]))[0].r;
    check("Song-Suche liefert Treffer mit Titel, Künstler und Startvorschlag", Array.isArray(found) && found.length > 0 && found[0].title && "vs" in found[0], JSON.stringify(found[0]));
    check("Zu kurze Suche liefert nichts", (await q("select public.rpc_battle_search($1, $2, '') r", [code, d.a]))[0].r.length === 0);

    // Wahl: Jury darf nicht, Teilnehmer A mit Song, B nur mit Namen
    check("Jury darf keinen Song wählen", /battle_not_battler/.test(await fails(() => q("select public.rpc_battle_pick($1, $2, null::uuid, 'Egal', 0)", [code, d.jury]))));
    check("Weder Song noch Name: abgelehnt", /battle_no_song/.test(await fails(() => q("select public.rpc_battle_pick($1, $2, null::uuid, ' ', 0)", [code, d.a]))));
    check("Unbekannte Song-ID abgelehnt", /battle_bad_song/.test(await fails(() => q("select public.rpc_battle_pick($1, $2, $3::uuid, null, 0)", [code, d.a, randomUUID()]))));
    await q("select public.rpc_battle_pick($1, $2, $3::uuid, null, 9999)", [code, d.a, found[0].id]);
    l = await lob(id);
    check("Wahl A gespeichert, Startstelle auf höchstens 22 s begrenzt", l.quiz_state === "pick" && l.quiz_options.duel.picks.a.songId === found[0].id && l.quiz_options.duel.picks.a.start === 22, JSON.stringify(l.quiz_options.duel.picks.a));
    check("Zweite Wahl derselben Person abgelehnt", /battle_already_picked/.test(await fails(() => q("select public.rpc_battle_pick($1, $2, $3::uuid, null, 0)", [code, d.a, found[0].id]))));
    await q("select public.rpc_battle_pick($1, $2, null::uuid, 'Mein Lieblingssong', 0)", [code, d.b]);
    l = await lob(id);
    check("Beide gewählt: Ausschnitt A läuft", l.quiz_state === "play_a" && l.quiz_options.duel.picks.b.free === true, l.quiz_state);
    check("Jury kann jetzt noch nicht entscheiden", /quiz_closed/.test(await fails(() => q("select public.rpc_battle_judge($1, $2, 'a')", [code, d.jury]))));
    await tick(id);
    check("Takt: Ausschnitt B läuft", (await lob(id)).quiz_state === "play_b");
    await tick(id);
    check("Takt: Jury ist dran", (await lob(id)).quiz_state === "judge");
    check("Nur die Jury darf entscheiden", /battle_not_jury/.test(await fails(() => q("select public.rpc_battle_judge($1, $2, 'a')", [code, d.a]))));
    check("Falsche Seite abgelehnt", /battle_bad_side/.test(await fails(() => q("select public.rpc_battle_judge($1, $2, 'c')", [code, d.jury]))));
    await q("select public.rpc_battle_judge($1, $2, 'b')", [code, d.jury]);
    l = await lob(id);
    let pts = await pointsOf(id);
    check("Jury entscheidet B: B bekommt 1 Punkt, sonst keiner", l.quiz_state === "reveal" && pts[d.b] === 1 && pts[d.a] === 0 && pts[d.jury] === 0 && l.quiz_reveal.winner === "b", JSON.stringify(pts));
    check("Auflösung nennt beide Songs", l.quiz_reveal.a.title && l.quiz_reveal.b.title === "Mein Lieblingssong");
    bump(d.a); bump(d.b);

    // Duell 2: Jury entscheidet nicht -> unentschieden
    await tick(id);
    l = await lob(id);
    d = l.quiz_options.duel;
    check("Duell 2: neue Rollen, neue Jury", l.quiz_index === 2 && l.quiz_state === "pick" && !roles.includes(d.jury), JSON.stringify([l.quiz_index, d.jury]));
    roles.push(d.jury);
    await q("select public.rpc_battle_pick($1, $2, null::uuid, 'Song X', 0)", [code, d.a]);
    await q("select public.rpc_battle_pick($1, $2, null::uuid, 'Song Y', 0)", [code, d.b]);
    await tick(id); await tick(id);
    const before = await pointsOf(id);
    await tick(id); // Jury schweigt
    l = await lob(id);
    const after = await pointsOf(id);
    check("Jury schweigt: unentschieden, keine Punkte", l.quiz_state === "reveal" && l.quiz_reveal.winner === null && JSON.stringify(before) === JSON.stringify(after));
    bump(d.a); bump(d.b);

    // Duell 3: Zeit läuft ab, bevor jemand gewählt hat -> Zufallssongs
    await tick(id);
    l = await lob(id);
    d = l.quiz_options.duel;
    check("Duell 3: dritte Person ist Jury", l.quiz_index === 3 && !roles.includes(d.jury));
    roles.push(d.jury);
    await tick(id);
    l = await lob(id);
    check("Keiner hat gewählt: beide bekommen einen Zufallssong, der Ausschnitt läuft", l.quiz_state === "play_a" && l.quiz_options.duel.picks.a.title && l.quiz_options.duel.picks.b.title, JSON.stringify(l.quiz_options.duel.picks));
    bump(d.a); bump(d.b);
    await tick(id); await tick(id);
    await q("select public.rpc_battle_judge($1, $2, 'a')", [code, d.jury]);
    await tick(id); // Auflösung -> Ende
    l = await lob(id);
    check("Nach 3 Duellen ist das Spiel beendet", l.phase === "finished", l.phase);
    pts = await pointsOf(id);
    check("Gesamt: 2 entschiedene Duelle = 2 Punkte", Object.values(pts).reduce((a, b) => a + b, 0) === 2, JSON.stringify(pts));
    check("Jeder war genau einmal Jury und trat zweimal an", roles.length === 3 && new Set(roles).size === 3 && [...battlers.values()].every((n) => n === 2) && battlers.size === 3, JSON.stringify([...battlers.values()]));
    const rows = await q("select count(*)::int n from public.series_results where lobby_id = $1", [id]);
    check("Wertung mit Plätzen gespeichert", rows[0].n === 3);

    // ---------- 2) Bots übernehmen ----------
    const [{ code: code2, host_player_id: host2 }] = await q("select * from public.rpc_create_lobby('Mensch', 'private', 12, 60)");
    const [{ id: id2 }] = await q("select id from public.lobbies where code = $1", [code2]);
    ids.push(id2);
    await q("select public.rpc_add_bot($1, $2, 'Bot 1', 2::smallint)", [id2, host2]);
    await q("select public.rpc_add_bot($1, $2, 'Bot 2', 2::smallint)", [id2, host2]);
    await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = 'battle', series_index = 1, series_total = 1, phase = 'quiz' where id = $1", [id2]);
    await q("select public._quiz_begin($1)", [id2]);
    let guard = 0;
    while (guard++ < 40 && (await lob(id2)).phase === "quiz") {
      const cur = await lob(id2);
      await q("update public.lobbies set quiz_started_at = now() - interval '30 seconds' where id = $1", [id2]);
      await q("select public._battle_bot_tick()");
      const after = await lob(id2);
      if (after.quiz_state === cur.quiz_state && after.quiz_index === cur.quiz_index) {
        // Mensch ist dran (Jury oder Teilnehmer): wie der Spieler handeln
        const dd = cur.quiz_options.duel;
        if (cur.quiz_state === "pick") {
          for (const s of ["a", "b"]) if (dd[s] === host2 && !dd.picks[s]) await q("select public.rpc_battle_pick($1, $2, null::uuid, 'Mein Song', 0)", [code2, host2]);
        } else if (cur.quiz_state === "judge" && dd.jury === host2) {
          await q("select public.rpc_battle_judge($1, $2, 'a')", [code2, host2]);
        } else {
          await tick(id2);
        }
      }
    }
    const fin = await lob(id2);
    check("Mit Bots läuft das ganze Spiel bis zum Ende", fin.phase === "finished", `${fin.phase} nach ${guard} Schritten`);
    const pts2 = await pointsOf(id2);
    check("Mit Bots wurden Punkte vergeben (3 Duelle, keine Zeitüberschreitung)", Object.values(pts2).reduce((a, b) => a + b, 0) === 3, JSON.stringify(pts2));

    // ---------- 3) Sicherheit ----------
    const [{ a1 }] = await q("select has_function_privilege('anon', 'public._battle_reveal(uuid, text)', 'execute') a1");
    check("_battle_reveal ist von außen gesperrt", a1 === false);
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    for (const id of ids) await q("delete from public.lobbies where id = $1", [id]).catch(() => {});
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
