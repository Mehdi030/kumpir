#!/usr/bin/env node
// Angriffstest für die Quiz-Modi (Migration 108–114): ein Fremder mit dem öffentlichen Schlüssel (anon)
// darf weder Lösungen lesen noch interne Funktionen aufrufen oder fremde Antworten abgeben.
// Aufruf: node db/scripts/test-quiz-security.mjs
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", "..", "apps", "web", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.includes("=") && !l.trim().startsWith("#"))
        .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()]),
);
const URL_ = env.NEXT_PUBLIC_SUPABASE_URL;
const KEY = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

let bad = 0;
const rest = async (path, init) => {
    const r = await fetch(`${URL_}/rest/v1/${path}`, { headers: H, ...init });
    let body = null;
    try { body = await r.json(); } catch { /* leer */ }
    return { status: r.status, body };
};
const check = (name, ok, extra = "") => {
    if (!ok) bad++;
    console.log(`${ok ? "✅ BLOCKIERT" : "❌ OFFEN    "} ${name} ${extra}`);
};

// 1) Geheime Tabellen: weder lesen noch schreiben
for (const t of ["quiz_secret", "quiz_answers", "quiz_bets", "mode_plays", "answer_misses", "word_terms", "word_categories", "letters_entries", "letters_done", "letters_votes"]) {
    const r = await rest(`${t}?select=*&limit=1`);
    check(`Tabelle ${t} nicht lesbar`, r.status >= 400 || (Array.isArray(r.body) && r.body.length === 0), `– HTTP ${r.status}`);
    const w = await rest(t, { method: "POST", body: JSON.stringify({}) });
    check(`Tabelle ${t} nicht beschreibbar`, w.status >= 400, `– HTTP ${w.status}`);
}

// 2) Lösung steckt nicht in öffentlich lesbaren Lobby-Feldern (nur nach der Auflösung)
const lob = await rest("lobbies?select=code,quiz_state,quiz_options,quiz_reveal,current_song_id&phase=eq.quiz&limit=5");
const leaks = (Array.isArray(lob.body) ? lob.body : []).filter((l) => l.quiz_state === "question" && l.quiz_reveal);
check("Während einer Frage ist quiz_reveal leer", leaks.length === 0, `– ${Array.isArray(lob.body) ? lob.body.length : 0} laufende Quiz-Lobbys geprüft`);

// 3) song_pool: Titel/Künstler/Jahr nicht abrufbar
const sp = await rest("song_pool?select=title,artist,release_year&limit=1");
check("song_pool: Titel/Künstler/Jahr nicht lesbar", sp.status >= 400, `– HTTP ${sp.status}`);

// 4) Interne Funktionen (_quiz_*) und Tick/Bot-Funktionen nicht aufrufbar
const fakeId = "00000000-0000-0000-0000-000000000000";
const internals = [
    ["_quiz_next", { p_lobby_id: fakeId }],
    ["_quiz_reveal", { p_lobby_id: fakeId }],
    ["_quiz_finish", { p_lobby_id: fakeId }],
    ["_quiz_tick", { p_lobby_id: fakeId }],
    ["_quiz_bot_tick", {}],
    ["_quiz_do_answer", { p_lobby_id: fakeId, p_player_id: fakeId, p_answer: "x" }],
    ["_quiz_do_choose", { p_lobby_id: fakeId, p_player_id: fakeId, p_choice: "x" }],
    ["_quiz_do_pick", { p_lobby_id: fakeId, p_player_id: fakeId, p_song_id: fakeId }],
    ["_quiz_begin", { p_lobby_id: fakeId }],
    ["_teams_decided", { p_lobby_id: fakeId }],
    ["_award_live_song_achievements", { p_user_id: fakeId, p_lobby_id: fakeId, p_match_id: fakeId, p_ms: 1, p_combo: 9 }],
    ["_next_alive", { p_lobby_id: fakeId, p_from: fakeId, p_dir: 1 }],
    ["_letters_spin", { p_lobby_id: fakeId }],
    ["_letters_reveal", { p_lobby_id: fakeId }],
    ["_letters_begin_category", { p_lobby_id: fakeId }],
    ["_letters_do_submit", { p_lobby_id: fakeId, p_player_id: fakeId, p_text: "x" }],
    ["_letters_do_vote", { p_lobby_id: fakeId, p_player_id: fakeId, p_choice: 1 }],
    ["_letters_pick_cands", { p_lobby_id: fakeId }],
    ["_letters_start_vote", { p_lobby_id: fakeId }],
];
for (const [fn, args] of internals) {
    const r = await rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });
    check(`Funktion ${fn} für Fremde gesperrt`, r.status === 401 || r.status === 403 || r.status === 404, `– HTTP ${r.status}`);
}

// 5) Öffentliche Quiz-Funktionen: ohne gültige Sitzung nichts möglich
const pub = [
    ["rpc_quiz_answer", { p_code: "ZZZZ", p_player_id: fakeId, p_answer: "x" }],
    ["rpc_quiz_choose", { p_code: "ZZZZ", p_player_id: fakeId, p_choice: "x" }],
    ["rpc_quiz_buzz", { p_code: "ZZZZ", p_player_id: fakeId }],
    ["rpc_quiz_pick", { p_code: "ZZZZ", p_player_id: fakeId, p_song_id: fakeId }],
    ["rpc_quiz_bet", { p_code: "ZZZZ", p_player_id: fakeId, p_pick: fakeId }],
    ["rpc_quiz_status", { p_code: "ZZZZ", p_player_id: fakeId }],
    ["rpc_letters_submit", { p_code: "ZZZZ", p_player_id: fakeId, p_text: "Berlin" }],
    ["rpc_letters_done", { p_code: "ZZZZ", p_player_id: fakeId }],
    ["rpc_letters_vote", { p_code: "ZZZZ", p_player_id: fakeId, p_choice: 1 }],
];
for (const [fn, args] of pub) {
    const r = await rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });
    check(`${fn} mit erfundenem Spieler abgelehnt`, r.status >= 400, `– HTTP ${r.status} ${JSON.stringify(r.body?.message ?? "").slice(0, 60)}`);
}

// 6) Modus setzen ohne Host-Rechte
const m = await rest("rpc/set_lobby_mode", { method: "POST", body: JSON.stringify({ p_lobby_id: fakeId, p_me_player_id: fakeId, p_mode: "duel" }) });
check("set_lobby_mode ohne Host-Rechte abgelehnt", m.status >= 400, `– HTTP ${m.status}`);
const m2 = await rest("rpc/set_lobby_mode", { method: "POST", body: JSON.stringify({ p_lobby_id: fakeId, p_me_player_id: fakeId, p_mode: "teleport" }) });
check("Alter Modus teleport nicht mehr annehmbar", m2.status >= 400, `– HTTP ${m2.status}`);

// 7) Statistik-Funktion für Endstand: gibt nur Zahlen zurück, keine Namen/Lösungen
const st = await rest("rpc/get_match_answer_stats", { method: "POST", body: JSON.stringify({ p_code: "ZZZZ" }) });
check("get_match_answer_stats liefert für unbekannten Code nichts", st.status === 200 && Array.isArray(st.body) && st.body.length === 0, `– HTTP ${st.status}`);

console.log(bad ? `\n${bad} Lücke(n) gefunden!` : "\nAlle Quiz-Angriffe blockiert, 0 Lücken.");
process.exit(bad ? 1 : 0);
