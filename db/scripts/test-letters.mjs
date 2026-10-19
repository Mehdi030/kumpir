#!/usr/bin/env node
// Prüft den Modus "Roulette" (Migration 127) mit einer echten Test-Lobby (wird am Ende gelöscht):
// Buchstabe + 3 Kategorien -> Eingaben (richtig, Tippfehler, doppelt, falsch) -> Auflösung -> 3 Kategorien -> Ende.
// Aufruf: node db/scripts/test-letters.mjs
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
const expire = (id) => q("update public.lobbies set quiz_ends_at = now() - interval '1 second' where id = $1", [id]);
const tick = async (id) => {
    await expire(id);
    await q("select public._quiz_tick($1)", [id]);
    return (await q("select quiz_state, quiz_index, quiz_options, quiz_reveal, phase from public.lobbies where id = $1", [id]))[0];
};

let id = null;
try {
    const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Roulette', 'private', 12, 60)");
    [{ id }] = await q("select id from public.lobbies where code = $1", [code]);
    for (let i = 1; i < 3; i++) await q("select public.rpc_add_bot($1, $2, $3, $4::smallint)", [id, host, `Bot ${i}`, i === 1 ? 1 : 3]);
    // der Host bleibt ein Mensch
    await q("update public.lobbies set created_at = now() + interval '2 hours', game_mode = 'letters', phase = 'countdown', countdown_ends_at = now(), series_index = 1, series_total = 1 where id = $1", [id]);
    await q("select public.rpc_advance_from_countdown($1)", [id]);

    let l = (await q("select phase, quiz_state, quiz_index, quiz_total, quiz_options, game_mode from public.lobbies where id = $1", [id]))[0];
    check("Roulette läuft (Zustand spin)", l.phase === "quiz" && l.quiz_state === "spin" && l.game_mode === "letters", `${l.phase}/${l.quiz_state}`);
    const letter = String(l.quiz_options?.letter ?? "");
    let cands = l.quiz_options?.cands ?? [];
    check("ein Buchstabe und drei verschiedene Kategorien zur Abstimmung", /^[A-Z]$/.test(letter) && cands.length === 3 && new Set(cands.map((c) => c.id)).size === 3, `${letter} ${cands.map((c) => c.name).join(", ")}`);
    check("3 Kategorien = 3 Fragen", l.quiz_total === 3);

    // keine Punkte-Lecks: Eingaben/Wortlisten sind für Clients nicht lesbar
    for (const t of ["word_terms", "letters_entries", "word_categories"]) {
        const [g] = await q("select has_table_privilege('anon', $1, 'select') a, has_table_privilege('authenticated', $1, 'select') b", [`public.${t}`]);
        check(`Tabelle ${t} nicht lesbar für Clients`, !g.a && !g.b);
    }

    for (let round = 0; round < 3; round++) {
        let chosenWanted = null;
        if (round === 0) {
            // Mehrheit: Host + Bot 1 wählen Karte 2, Bot 2 Karte 3 (Bots kurz als Menschen behandeln, damit ihre Stimme zählt)
            const bots = await q("select player_id from public.players where lobby_id = $1 and is_bot and player_id <> $2 order by seat_index", [id, host]);
            await q("update public.players set is_bot = false where lobby_id = $1 and player_id = any($2)", [id, bots.map((b) => b.player_id)]);
            await q("select public._letters_do_vote($1, $2, 2)", [id, host]);
            await q("select public._letters_do_vote($1, $2, 2)", [id, bots[0].player_id]);
            await q("select public._letters_do_vote($1, $2, 3)", [id, bots[1].player_id]);
            const [t] = await q("select quiz_options -> 'tally' as t from public.lobbies where id = $1", [id]);
            check("Zwischenstand der Abstimmung 0 / 2 / 1", JSON.stringify(t.t) === "[0,2,1]", JSON.stringify(t.t));
            let err = "";
            try { await q("select public._letters_do_vote($1, $2, 4)", [id, host]); } catch (e) { err = e.message; }
            check("Karte 4 gibt es nicht", /quiz_bad_choice/.test(err), err);
            await q("update public.players set is_bot = true where lobby_id = $1 and player_id = any($2)", [id, bots.map((b) => b.player_id)]);
            chosenWanted = cands[1].id;
            const [ends] = await q("select quiz_ends_at - now() as rest from public.lobbies where id = $1", [id]);
            check("alle Menschen haben gewählt (Bots zählen nicht): bleibt höchstens die Walzen-Zeit", !!ends.rest);
            l = await tick(id);
            check("Mehrheit entscheidet", l.quiz_options?.cat?.id === chosenWanted, JSON.stringify(l.quiz_options?.cat));
        } else {
            l = await tick(id); // reveal -> neue Abstimmung
            check(`Abstimmung ${round + 1}: drei neue, verschiedene Kategorien`, l.quiz_state === "vote" && (l.quiz_options?.cands ?? []).length === 3, `${l.quiz_state}`);
            cands = l.quiz_options?.cands ?? [];
            const played = l.quiz_options?.played ?? [];
            check("keine schon gespielte Kategorie dabei", cands.every((c) => !played.includes(c.id)) && new Set(cands.map((c) => c.id)).size === 3);
            await q("select public._letters_do_vote($1, $2, 1)", [id, host]);
            l = await tick(id);
        }
        check(`Kategorie ${round + 1} läuft`, l.quiz_state === "question" && l.quiz_index === round + 1, `${l.quiz_state}/${l.quiz_index}`);
        const cat = l.quiz_options?.cat;
        const catId = cat.id;
        // Einwort-Begriffe (7–14 Buchstaben) bevorzugen: Tippfehler-Test bleibt eindeutig; sonst alles Mögliche
        const pick = (re) =>
            q(
                "select label, key_norm from (select distinct on (label) label, key_norm from public.word_terms where category_id = $1 and initial = lower($2) and label ~ $3 order by label, length(key_norm) desc) x order by length(label) desc, label limit 12",
                [catId, letter, re],
            );
        let terms = await pick("^[A-Za-zÄÖÜäöüß]{7,14}$");
        if (terms.length < 4) terms = await pick("^[A-Za-zÄÖÜäöüß ]{6,}$");
        if (terms.length < 4) terms = await pick("^.{3,}$");
        check(`Kategorie ${round + 1} (${cat.name}) hat Begriffe mit ${letter}`, terms.length >= 4, String(terms.length));
        const [v1, v2, v3, v4] = terms.map((t) => t.label);
        const submit = (t) => q("select public._letters_do_submit($1, $2, $3)", [id, host, t]);
        await submit(v1.toLowerCase());
        await submit(v2);
        await submit(v3.toUpperCase());
        // Tippfehler: ein Buchstabe in der Mitte doppelt
        const typo = (s) => {
            let m = Math.max(2, Math.floor(s.length / 2));
            while (m < s.length - 1 && !/[A-Za-zÄÖÜäöüß]/.test(s[m])) m++;
            return s.slice(0, m) + s[m] + s.slice(m);
        };
        await submit(typo(v4)); // zählt (kleiner Tippfehler)
        await submit(typo(v1)); // gleicher Begriff wie v1 -> doppelt
        await submit(`${letter}xqzjkv`); // Unsinn mit richtigem Anfang
        await submit(letter === "S" ? "Bremen" : "Sydney"); // falscher Anfangsbuchstabe
        const dupSame = await submit(v2); // exakt dieselbe Eingabe nochmal
        check("dieselbe Eingabe nochmal wird nicht doppelt gespeichert", dupSame[0].added === false || dupSame[0]?._letters_do_submit?.added === false);

        const [st] = await q("select public.rpc_quiz_status($1, $2) s", [code, host]);
        check("rpc_quiz_status zeigt nur meine Eingaben", Array.isArray(st.s.mine) && st.s.mine.length === 7, JSON.stringify(st.s.mine).slice(0, 80));

        await q("select public.rpc_letters_done($1, $2)", [code, host]);
        const [ends] = await q("select quiz_ends_at - now() as rest from public.lobbies where id = $1", [id]);
        check("Fertig (einziger Mensch) verkürzt die Zeit", ends.rest && Number(ends.rest.seconds ?? 0) < 3, JSON.stringify(ends.rest));

        l = await tick(id); // question -> reveal
        check("Auflösung", l.quiz_state === "reveal", l.quiz_state);
        const res = l.quiz_reveal?.results ?? [];
        const me = res.find((r) => r.playerId === host);
        check("richtige Begriffe gezählt (3 + 1 mit Tippfehler)", me?.points === 4, `Punkte ${me?.points}, richtig ${JSON.stringify(me?.valid)}`);
        check("doppelt und falsch getrennt aufgeführt", (me?.dup ?? []).length === 1 && (me?.bad ?? []).length === 2, `doppelt ${JSON.stringify(me?.dup)}, falsch ${JSON.stringify(me?.bad)}`);
        const asc = res.every((r, i) => i === 0 || res[i - 1].points <= r.points);
        check("Ergebnisse aufsteigend (Letzter zuerst)", asc, res.map((r) => `${r.name}:${r.points}`).join(" "));
        check("Bots haben Begriffe", res.filter((r) => r.name.startsWith("Bot")).every((r) => r.points >= 1));
        check("Auflösung enthält Schreibweise + Begriff und die Show-Dauer", (me?.valid ?? []).every((v) => v.t && v.l) && l.quiz_reveal?.last === (round === 2), `last=${l.quiz_reveal?.last}`);
    }

    l = await tick(id); // letzte Auflösung -> Ende
    check("nach 3 Kategorien beendet", l.phase === "finished", l.phase);
    const rows = await q("select name, place, song_points from public.series_results where lobby_id = $1 order by place", [id]);
    check("Wertung mit Plätzen vorhanden", rows.length === 3 && rows[0].place === 1, JSON.stringify(rows));
    const [mine] = await q("select song_points from public.players where lobby_id = $1 and player_id = $2", [id, host]);
    check("Summe der drei Kategorien = 12 Punkte", Number(mine.song_points) === 12, String(mine.song_points));
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    if (id) await q("delete from public.lobbies where id = $1", [id]).catch(() => {});
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
