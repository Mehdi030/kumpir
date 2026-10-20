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
        check("Wörter-Karte steht 13 s (rote Wörter vorhanden) – Einspruch möglich", l.quiz_reveal?.mapSecs === 13, String(l.quiz_reveal?.mapSecs));

        // ---- Einspruch ----
        const appeal = (t) => q("select public.rpc_letters_appeal($1, $2, $3) r", [code, host, t]);
        const bots2 = await q("select player_id from public.players where lobby_id = $1 and is_bot order by seat_index", [id]);
        const vote = (who, owner, t, yes) => q("select public.rpc_letters_appeal_vote($1, $2, $3, $4, $5) r", [code, who, owner, t, yes]);
        const results = async () => (await q("select quiz_reveal from public.lobbies where id = $1", [id]))[0].quiz_reveal.results.find((r) => r.playerId === host);
        const pts = async () => Number((await q("select song_points from public.players where lobby_id = $1 and player_id = $2", [id, host]))[0].song_points);
        if (round === 0) {
            // allein unter Bots: Einspruch gilt sofort
            const before = await pts();
            const w = me.bad[0];
            await appeal(w);
            const r = await results();
            check("Einspruch (nur Bots dabei): sofort angenommen, +1 Punkt", (await pts()) === before + 1 && r.points === me.points + 1 && r.valid.some((v) => v.t === w) && !r.bad.includes(w), JSON.stringify(r.bad));
            let err = "";
            try { await appeal(w); } catch (e) { err = e.message; }
            check("derselbe Einspruch nicht doppelt", !err || /appeal_not_possible/.test(err), err);
            err = "";
            try { await appeal(me.valid[0].t); } catch (e) { err = e.message; }
            check("Einspruch gegen ein richtiges Wort geht nicht", /appeal_not_possible/.test(err), err);
        }
        if (round === 1) {
            // zwei weitere Menschen (Bots kurz als Menschen): Mehrheit der anderen entscheidet
            await q("update public.players set is_bot = false where lobby_id = $1 and player_id = any($2)", [id, bots2.map((b) => b.player_id)]);
            const before = await pts();
            const [w1, w2] = me.bad;
            await appeal(w1);
            let err = "";
            try { await vote(host, host, w1, true); } catch (e) { err = e.message; }
            check("über den eigenen Einspruch darf man nicht abstimmen", /appeal_own/.test(err), err);
            await vote(bots2[0].player_id, host, w1, true);
            let r = await results();
            check("ein Ja von zwei anderen reicht noch nicht", r.bad.includes(w1) && (await pts()) === before);
            await vote(bots2[1].player_id, host, w1, true);
            r = await results();
            check("zwei Ja von zwei anderen: angenommen, +1 Punkt", r.valid.some((v) => v.t === w1) && (await pts()) === before + 1, JSON.stringify(r.bad));
            await appeal(w2);
            await vote(bots2[0].player_id, host, w2, false);
            const [ap] = await q("select status from public.letters_appeals where lobby_id = $1 and owner_id = $2 and text = $3", [id, host, w2]);
            check("ein Nein von zwei anderen: abgelehnt, Wort bleibt rot", ap.status === "rejected" && (await results()).bad.includes(w2) && (await pts()) === before + 1, ap.status);
            const [st] = await q("select public.rpc_quiz_status($1, $2) s", [code, host]);
            check("rpc_quiz_status zeigt die Einsprüche", (st.s.appeals ?? []).length === 2, JSON.stringify(st.s.appeals).slice(0, 120));
            await q("update public.players set is_bot = true where lobby_id = $1 and player_id = any($2)", [id, bots2.map((b) => b.player_id)]);
        }
        if (round === 2) {
            await q("update public.lobbies set quiz_started_at = now() - interval '30 seconds' where id = $1", [id]);
            let err = "";
            try { await appeal(me.bad[0]); } catch (e) { err = e.message; }
            check("nach Ende der Wörter-Karte kein Einspruch mehr", /appeal_closed/.test(err), err);
        }
    }

    l = await tick(id); // letzte Auflösung -> Ende
    check("nach 3 Kategorien beendet", l.phase === "finished", l.phase);
    const rows = await q("select name, place, song_points from public.series_results where lobby_id = $1 order by place", [id]);
    check("Wertung mit Plätzen vorhanden", rows.length === 3 && rows[0].place === 1, JSON.stringify(rows));
    const [mine] = await q("select song_points from public.players where lobby_id = $1 and player_id = $2", [id, host]);
    check("Summe der drei Kategorien = 12 Punkte + 2 angenommene Einsprüche", Number(mine.song_points) === 14, String(mine.song_points));
} catch (e) {
    console.error("FEHLER:", e.message);
    failed++;
} finally {
    if (id) await q("delete from public.lobbies where id = $1", [id]).catch(() => {});
}

// ---------- Host-Einstellungen, Statistik, Erfolge (Migration 130) ----------
let id2 = null;
try {
    const [acc] = await q("select id from public.profiles where lower(username) = 'claude'");
    const [{ code, host_player_id: host }] = await q("select * from public.rpc_create_lobby('Roulette', 'private', 12, 60)");
    [{ id: id2 }] = await q("select id from public.lobbies where code = $1", [code]);
    for (let i = 1; i < 3; i++) await q("select public.rpc_add_bot($1, $2, $3, $4::smallint)", [id2, host, `Bot ${i}`, 2]);
    await q("update public.lobbies set game_mode = 'letters', series_index = 1, series_total = 1 where id = $1", [id2]);
    const cfg = (c) => q("select public.set_letters_config($1, $2, $3::jsonb)", [id2, host, JSON.stringify(c)]);
    const fails = async (c) => { try { await cfg(c); return ""; } catch (e) { return e.message; } };
    check("Einstellungen: 6 Kategorien gibt es nicht", /letters_bad_config/.test(await fails({ cats: 6, secs: 45, off: [] })));
    check("Einstellungen: 50 Sekunden gibt es nicht", /letters_bad_config/.test(await fails({ cats: 3, secs: 50, off: [] })));
    const all = (await q("select name from public.word_categories where active order by name")).map((r) => r.name);
    check("Einstellungen: zu wenige Kategorien übrig wird abgelehnt", /letters_too_few_categories/.test(await fails({ cats: 3, secs: 45, off: all.slice(0, all.length - 3) })));
    const off = ["Länder", "Hauptstädte", "Städte", "Schauspieler", "Sänger", "Bands"];
    await cfg({ cats: 2, secs: 30, off: [...off, "Gibtsnicht"] });
    const [c1] = await q("select letters_cfg from public.lobbies where id = $1", [id2]);
    check("Einstellungen gespeichert (unbekannte Kategorie verworfen)", c1.letters_cfg.cats === 2 && c1.letters_cfg.secs === 30 && c1.letters_cfg.off.length === 6, JSON.stringify(c1.letters_cfg));

    // zwei Menschen (wegen "gewertet") – der Host mit Konto, ein Bot kurz als Mensch
    const [bot] = await q("select player_id from public.players where lobby_id = $1 and is_bot order by seat_index limit 1", [id2]);
    if (acc) await q("update public.players set user_id = $2 where lobby_id = $1 and player_id = $3", [id2, acc.id, host]);
    await q("update public.players set is_bot = false where lobby_id = $1 and player_id = $2", [id2, bot.player_id]);
    await q("update public.lobbies set created_at = now() + interval '2 hours', phase = 'countdown', countdown_ends_at = now() where id = $1", [id2]);
    await q("select public.rpc_advance_from_countdown($1)", [id2]);
    let l = (await q("select quiz_total, quiz_options, quiz_state from public.lobbies where id = $1", [id2]))[0];
    check("2 Kategorien eingestellt = 2 Fragen", l.quiz_total === 2, String(l.quiz_total));
    const offOk = (o) => (o?.cands ?? []).every((c) => !off.includes(c.name));
    check("ausgeschlossene Kategorien stehen nicht zur Wahl", (l.quiz_options?.cands ?? []).length === 3 && offOk(l.quiz_options), (l.quiz_options?.cands ?? []).map((c) => c.name).join(", "));
    let maxSub = 0;
    for (let round = 0; round < 2; round++) {
        if (round > 0) { l = await tick(id2); check(`Abstimmung ${round + 1} ohne ausgeschlossene Kategorien`, l.quiz_state === "vote" && offOk(l.quiz_options)); }
        await q("select public._letters_do_vote($1, $2, 1)", [id2, host]);
        await q("select public._letters_do_vote($1, $2, 1)", [id2, bot.player_id]);
        l = await tick(id2);
        const [t] = await q("select extract(epoch from quiz_ends_at - quiz_started_at) as secs from public.lobbies where id = $1", [id2]);
        check(`Kategorie ${round + 1}: Zeit 30 s`, l.quiz_state === "question" && Math.round(Number(t.secs)) === 30, `${l.quiz_state} ${t.secs}`);
        const catId = l.quiz_options.cat.id;
        const terms = await q("select distinct label from public.word_terms where category_id = $1 and initial = lower($2) limit 14", [catId, l.quiz_options.letter]);
        maxSub = Math.max(maxSub, Math.min(12, terms.length));
        for (const r of terms.slice(0, 12)) await q("select public._letters_do_submit($1, $2, $3)", [id2, host, r.label]);
        await q("select public._letters_do_submit($1, $2, 'Qwertzuiop')", [id2, host]);
        await q("select public.rpc_letters_done($1, $2)", [code, host]);
        await q("select public.rpc_letters_done($1, $2)", [code, bot.player_id]);
        l = await tick(id2); // -> Auflösung
    }
    l = await tick(id2); // letzte Auflösung -> Ende (+ Statistik)
    check("nach 2 Kategorien beendet", (await q("select phase from public.lobbies where id = $1", [id2]))[0].phase === "finished");
    if (acc) {
        const rr = await q("select * from public.roulette_rounds where lobby_id = $1 and user_id = $2 order by idx", [id2, acc.id]);
        check("Statistik: 2 Kategorien festgehalten, gewertet (2 Menschen)", rr.length === 2 && rr.every((r) => r.ranked && r.humans === 2 && r.correct >= 1 && r.bad === 1), JSON.stringify(rr.map((r) => [r.category, r.correct, r.bad, r.place])));
        const [mm] = await q("select * from public.roulette_matches where lobby_id = $1 and user_id = $2", [id2, acc.id]);
        check("Statistik: Match festgehalten", !!mm && mm.categories === 2 && mm.ranked && mm.place >= 1, JSON.stringify(mm));
        const ach = await q("select achievement_code from public.player_achievements where user_id = $1 and lobby_id = $2", [acc.id, id2]);
        check("Erfolg Wörterflut (12 richtige in einer Kategorie)", maxSub < 12 || ach.some((a) => a.achievement_code === "roulette_haul_12"), `${maxSub} Begriffe, ${JSON.stringify(ach)}`);
        // Auswertung wie ein angemeldeter Client
        await db.query("begin");
        await db.query("select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.sub', $2, true), set_config('role', 'authenticated', true)", [JSON.stringify({ sub: acc.id, role: "authenticated" }), acc.id]);
        const st = (await db.query("select public.get_my_roulette_stats() s")).rows[0].s;
        await db.query("rollback");
        check("get_my_roulette_stats liefert Runden, Wörter, Lieblingskategorie", st.rounds >= 2 && st.words >= 2 && Array.isArray(st.categories) && st.categories.length >= 1 && st.bestRound?.correct >= 1, JSON.stringify(st).slice(0, 160));
    } else console.log("(Testkonto 'claude' fehlt – Statistik-Prüfung übersprungen)");
} catch (e) {
    console.error("FEHLER (Einstellungen/Statistik):", e.message);
    failed++;
    await db.query("rollback").catch(() => {});
} finally {
    if (id2) {
        await q("delete from public.player_achievements where lobby_id = $1", [id2]).catch(() => {});
        await q("delete from public.roulette_rounds where lobby_id = $1", [id2]).catch(() => {});
        await q("delete from public.roulette_matches where lobby_id = $1", [id2]).catch(() => {});
        await q("delete from public.lobbies where id = $1", [id2]).catch(() => {});
    }
    await db.end();
}
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : "\nAlle Prüfungen bestanden.");
process.exit(failed ? 1 : 0);
