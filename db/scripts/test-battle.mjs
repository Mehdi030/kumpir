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

    // ---------- 2b) Wie Bots bewerten und wählen (Migration 144) ----------
    const [{ top, low, oldest, newest }] = await q(`select
        (select id from public.song_pool where preview_url is not null and archived_from is null order by (hits + 1.0) / (plays + 3.0) desc, plays desc limit 1) top,
        (select id from public.song_pool where preview_url is not null and archived_from is null order by (hits + 1.0) / (plays + 3.0) asc, plays asc limit 1) low,
        (select id from public.song_pool where preview_url is not null and archived_from is null and release_year is not null order by release_year asc limit 1) oldest,
        (select id from public.song_pool where preview_url is not null and archived_from is null and release_year is not null order by release_year desc limit 1) newest`);
    const avgScore = async (song, crit) => Number((await q("select avg(public._battle_song_score($1::uuid, $2, 'geschmack' || g::text))::float a from generate_series(1, 30) g", [song, crit]))[0].a);
    check("Hit-Faktor: bekannter Song bekommt einen höheren Wert als ein unbekannter", (await avgScore(top, "hit")) > (await avgScore(low, "hit")) + 0.1, `${(await avgScore(top, "hit")).toFixed(2)} vs ${(await avgScore(low, "hit")).toFixed(2)}`);
    check("Nostalgie: der älteste Song schlägt den neuesten", (await avgScore(oldest, "nostalgia")) > (await avgScore(newest, "nostalgia")) + 0.1, `${(await avgScore(oldest, "nostalgia")).toFixed(2)} vs ${(await avgScore(newest, "nostalgia")).toFixed(2)}`);
    check("Werte liegen immer zwischen 0 und 1", (await q("select min(v) >= 0 and max(v) <= 1 ok from (select public._battle_song_score(id, c, 't') v from public.song_pool, unnest(array['hit','nostalgia','sound','lyrics']) c limit 400) x"))[0].ok === true);
    check("Unbekannter Song (nur Name) bekommt einen neutralen Wert", Number((await q("select public._battle_song_score(null, 'hit', 'x') v"))[0].v) >= 0.3);

    const [{ code: code3, host_player_id: host3 }] = await q("select * from public.rpc_create_lobby('Mensch', 'private', 12, 60)");
    const [{ id: id3 }] = await q("select id from public.lobbies where code = $1", [code3]);
    ids.push(id3);
    await q("select public.rpc_add_bot($1, $2, 'Bot 1', 3::smallint)", [id3, host3]);
    await q("select public.rpc_add_bot($1, $2, 'Bot 2', 3::smallint)", [id3, host3]);
    await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = 'battle', series_index = 1, series_total = 1, phase = 'quiz' where id = $1", [id3]);
    await q("select public._quiz_begin($1)", [id3]);
    const bots = (await q("select player_id from public.players where lobby_id = $1 and is_bot order by seat_index", [id3])).map((r) => r.player_id);
    const judgeTrial = async (crit, a, b, seq) => {
        const dd = (await lob(id3)).quiz_options.duel;
        const pickJson = (x) => ({ songId: x, title: "t", artist: "k", start: 0, free: false });
        await q("update public.lobbies set quiz_state = 'judge', quiz_seq = $2, quiz_options = jsonb_set(jsonb_set(jsonb_set(jsonb_set(quiz_options, '{duel,jury}', to_jsonb($3::text)), '{duel,crit}', to_jsonb($4::text)), '{duel,picks,a}', $5::jsonb), '{duel,picks,b}', $6::jsonb), quiz_reveal = null where id = $1",
            [id3, seq, bots[0], crit, JSON.stringify(pickJson(a)), JSON.stringify(pickJson(b))]);
        await q("select public._battle_bot_judge($1)", [id3]);
        return (await lob(id3)).quiz_reveal.winner;
    };
    let aWins = 0, bWins = 0;
    for (let t = 100; t < 110; t++) { if ((await judgeTrial("hit", top, low, t)) === "a") aWins++; if ((await judgeTrial("hit", low, top, t + 50)) === "b") bWins++; }
    check("Profi-Jury (Hit-Faktor): der bekanntere Song gewinnt, egal ob er links oder rechts steht", aWins === 10 && bWins === 10, `${aWins}/10 und ${bWins}/10`);
    let nostWins = 0;
    for (let t = 200; t < 210; t++) if ((await judgeTrial("nostalgia", newest, oldest, t)) === "b") nostWins++;
    check("Profi-Jury (Nostalgie): der ältere Song gewinnt meistens", nostWins >= 8, `${nostWins}/10`);
    const pairs = await q("select a.id a, b.id b from (select id, row_number() over (order by random()) rn from public.song_pool where preview_url is not null and archived_from is null limit 40) a join (select id, row_number() over (order by random()) rn from public.song_pool where preview_url is not null and archived_from is null limit 40) b on a.rn = b.rn and a.id <> b.id");
    let soundA = 0;
    for (let t = 0; t < pairs.length; t++) if ((await judgeTrial("sound", pairs[t].a, pairs[t].b, 300 + t)) === "a") soundA++;
    check("Beim Sound entscheidet der Geschmack: bei vielen Paaren gewinnen beide Seiten (nicht immer links)", soundA >= pairs.length * 0.2 && soundA <= pairs.length * 0.8, `links ${soundA} von ${pairs.length}`);
    const t1 = [], t2 = [];
    for (let t = 0; t < 3; t++) { t1.push(await judgeTrial("sound", pairs[0].a, pairs[0].b, 900 + t)); }
    check("Derselbe Bot entscheidet dasselbe Paar immer gleich (fester Geschmack, kein Würfeln)", new Set(t1).size === 1, t1.join(","));
    void t2;

    // Duellanten: Profis wählen im Schnitt passendere Songs als Anfänger
    const pickAvg = async (skill) => {
        await q("update public.players set bot_skill = $2 where lobby_id = $1 and is_bot", [id3, skill]);
        let sum = 0;
        for (let t = 0; t < 14; t++) {
            await q("update public.lobbies set quiz_state = 'pick', quiz_seq = $2, used_song_ids = '{}', quiz_options = jsonb_set(jsonb_set(quiz_options, '{duel,picks}', '{}'::jsonb), '{duel,crit}', '\"hit\"') where id = $1", [id3, 500 + t]);
            await q("update public.lobbies set quiz_options = jsonb_set(jsonb_set(quiz_options, '{duel,a}', to_jsonb($2::text)), '{duel,b}', to_jsonb($3::text)) where id = $1", [id3, bots[0], bots[1]]);
            await q("select public._battle_bot_pick($1, 'a')", [id3]);
            const sid = (await lob(id3)).quiz_options.duel.picks.a?.songId;
            sum += Number((await q("select public._battle_song_score($1::uuid, 'hit', $2) v", [sid, bots[0]]))[0].v);
        }
        return sum / 14;
    };
    const lowSkill = await pickAvg(1), highSkill = await pickAvg(3);
    check("Profi-Bots wählen im Schnitt passendere Songs als Anfänger-Bots", highSkill > lowSkill + 0.03, `Profi ${highSkill.toFixed(2)} vs Anfänger ${lowSkill.toFixed(2)}`);

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
