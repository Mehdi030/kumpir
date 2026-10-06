// Spielt als Konto "Claude" 5 Matches gegen Bots – über DIESELBEN Schnittstellen wie der Browser
// (Supabase-RPCs mit Konto-Token + Session-Header). Jedes Match hat andere Einstellungen und andere
// Eingaben. Am Ende wird die Konto-Statistik (get_my_profile_stats, wie auf /profile) mit dem
// verglichen, was tatsächlich eingegeben wurde.
//
//   node db/scripts/play-claude.mjs            (legt "Claude" an, falls nötig, und spielt)
//   node db/scripts/play-claude.mjs --account-only   (nur das Konto anlegen/anmelden, nicht spielen)
//   node db/scripts/play-claude.mjs --reset    (vorher den Konto-Verlauf von Claude leeren)
//
// Zugangsdaten für "Claude" landen in db/.env.local (CLAUDE_TEST_EMAIL / CLAUDE_TEST_PASSWORD, nicht im Git).
import { createClient } from "@supabase/supabase-js";
import { readFileSync, appendFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import pg from "pg";

const env = (f) =>
    Object.fromEntries(
        readFileSync(f, "utf8")
            .split(/\r?\n/)
            .filter((l) => l.includes("=") && !l.startsWith("#"))
            .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
    );
const web = env("apps/web/.env.local");
const dbe = env("db/.env.local");
const URL_ = web.NEXT_PUBLIC_SUPABASE_URL;
const ANON = web.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const SERVICE = web.SUPABASE_SERVICE_ROLE_KEY;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const db = new pg.Client({ host: dbe.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: dbe.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
const q = async (sql, args = []) => (await db.query(sql, args)).rows;

// ---------- Konto "Claude" ----------
async function ensureClaude() {
    let email = dbe.CLAUDE_TEST_EMAIL;
    let password = dbe.CLAUDE_TEST_PASSWORD;
    if (!email) {
        email = "claude-spieltest@example.invalid";
        password = randomUUID() + "Aa1";
        const r = await fetch(`${URL_}/auth/v1/admin/users`, {
            method: "POST",
            headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json" },
            body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { username: "Claude" } }),
        });
        const j = await r.json();
        if (!r.ok) throw new Error("Konto anlegen: " + JSON.stringify(j));
        appendFileSync("db/.env.local", `\n# Testkonto "Claude" (play-claude.mjs)\nCLAUDE_TEST_EMAIL=${email}\nCLAUDE_TEST_PASSWORD=${password}\n`);
        console.log(`👤 Konto "Claude" angelegt (Zugangsdaten in db/.env.local)`);
    }
    const t = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
        method: "POST",
        headers: { apikey: ANON, "Content-Type": "application/json" },
        body: JSON.stringify({ email, password }),
    });
    const tok = await t.json();
    if (!tok.access_token) throw new Error("Anmeldung fehlgeschlagen: " + JSON.stringify(tok));
    // Anzeigename "Claude" (Benutzernamen sind fürs Login immer klein geschrieben) – wie in den Konto-Einstellungen
    const upd = await clientFor(tok.access_token, randomUUID()).rpc("update_my_profile", { p_display_name: "Claude", p_avatar_emoji: "🤖", p_avatar_color: "#d97757" });
    if (upd.error) throw new Error("Profil: " + upd.error.message);
    const [p] = await q("select id, username, display_name, role, status from profiles where id = $1", [tok.user.id]);
    console.log(`🔑 Angemeldet als ${p.display_name} (Benutzername ${p.username}, Rolle ${p.role}, Status ${p.status})`);
    return { uid: tok.user.id, token: tok.access_token, username: p.display_name };
}

function clientFor(token, session) {
    return createClient(URL_, ANON, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: `Bearer ${token}`, "x-kumpir-session": session } },
    });
}

// ---------- Die 5 Matches: jeweils andere Einstellungen + andere Eingaben ----------
// Schritte pro Zug (wenn Claude die Kartoffel hat):
//   ["wait", ms] warten · ["wrong", text] falsche Antwort · ["title"] / ["title-lower"] Titel · ["artist"] Interpret
//   ["explode"] nichts mehr tippen, Kartoffel explodieren lassen
const WRONG = ["Kartoffelsalat", "Quatsch mit Soße", "Keine Ahnung echt", "Döner Song", "Zzz Testlied", "Lalala Remix", "Ofenkartoffel Blues"];
const MATCHES = [
    {
        name: "Match 1 – Aufwärmen",
        playlist: "80er Hits", speed: "normal", bots: [1, 1],
        info: "2 Anfänger-Bots, Tempo normal; Claude tippt immer den richtigen Titel nach ~2,5 s",
        turn: () => [["wait", 2500], ["title"]],
    },
    {
        name: "Match 2 – Nur Interpreten",
        playlist: "Rock-Klassiker", speed: "fast", bots: [2, 2, 2],
        info: "3 Mittel-Bots, Tempo Blitz; Claude nennt nur den Interpreten (½ Punkt), im 1. Zug vorher 1× falsch, ab Zug 4 explodiert er absichtlich",
        turn: (n) => (n >= 4 ? [["explode"]] : n === 1 ? [["wait", 1500], ["wrong", WRONG[0]], ["wait", 1300], ["artist"]] : [["wait", 3000], ["artist"]]),
    },
    {
        name: "Match 3 – Viel daneben",
        playlist: "Deutschrap aktuell", speed: "calm", bots: [1, 2, 3, 1],
        info: "4 gemischte Bots, Tempo gemütlich; jeder Zug: 2× falsch, dann Titel nach ~6 s",
        turn: (n) => [["wait", 2000], ["wrong", WRONG[(n * 2) % WRONG.length]], ["wait", 1500], ["wrong", WRONG[(n * 2 + 1) % WRONG.length]], ["wait", 2000], ["title"]],
    },
    {
        name: "Match 4 – Gegen den Profi",
        playlist: "2000er Old School", speed: "normal", bots: [3],
        info: "1 Profi-Bot (Duell), Tempo normal; Zug 1 Titel, Zug 2 Interpret, ab Zug 3 nur noch falsche Antworten bis zur Explosion",
        turn: (n) => (n === 1 ? [["wait", 2000], ["title"]] : n === 2 ? [["wait", 4000], ["artist"]] : [["wait", 1200], ["wrong", WRONG[3]], ["wait", 1300], ["wrong", WRONG[4]], ["wait", 1300], ["wrong", WRONG[5]], ["explode"]]),
    },
    {
        name: "Match 5 – Großes Feld, Combo",
        playlist: "Deutsch-Pop", speed: "fast", bots: [1, 2, 1, 3, 2],
        info: "5 gemischte Bots, Tempo Blitz; Claude tippt den Titel klein & ohne Satzzeichen nach ~1,6 s (Combo-Serie), jeder 3. Zug nur Interpret",
        turn: (n) => (n % 3 === 0 ? [["wait", 2200], ["artist"]] : [["wait", 1600], ["title-lower"]]),
    },
];

// ---------- Ein Match spielen ----------
async function playMatch(acc, plan, idx) {
    const session = randomUUID();
    const sb = clientFor(acc.token, session);
    const rpc = async (fn, args) => {
        const { data, error } = await sb.rpc(fn, args);
        return { data, error: error?.message ?? null };
    };
    const log = [];
    const say = (s) => console.log("   " + s);
    console.log(`\n🎮 ${plan.name}\n   ${plan.info}\n   Playlist: ${plan.playlist}`);

    let r = await rpc("rpc_create_lobby", { p_host_name: acc.username, p_privacy: "private", p_max_players: 8, p_round_seconds: 25, p_user_id: acc.uid, p_round_speed: plan.speed });
    if (r.error) throw new Error("create: " + r.error);
    const row = Array.isArray(r.data) ? r.data[0] : r.data;
    const code = row.code, me = row.host_player_id;
    r = await rpc("rpc_join_lobby", { p_code: code, p_player_id: me, p_name: acc.username, p_user_id: acc.uid });
    if (r.error) throw new Error("join: " + r.error);
    const { data: lob } = await sb.from("lobbies").select("id").eq("code", code).single();
    const lobbyId = lob.id;
    r = await rpc("set_lobby_topic_filter", { p_lobby_id: lobbyId, p_me_player_id: me, p_categories: [plan.playlist] });
    if (r.error) throw new Error("filter: " + r.error);
    const botNames = ["Bot Anna", "Bot Ben", "Bot Cleo", "Bot Dino", "Bot Emma"];
    for (let i = 0; i < plan.bots.length; i++) {
        r = await rpc("rpc_add_bot", { p_lobby_id: lobbyId, p_me_player_id: me, p_bot_name: botNames[i], p_skill: plan.bots[i] });
        if (r.error) throw new Error("bot: " + r.error);
    }
    say(`Lobby ${code} erstellt, ${plan.bots.length} Bot(s): ${plan.bots.map((s, i) => `${botNames[i]} (${["", "Anfänger", "Mittel", "Profi"][s]})`).join(", ")}`);
    r = await rpc("rpc_begin_topic_vote", { p_lobby_id: lobbyId, p_player_id: me });
    if (r.error) throw new Error("start: " + r.error);

    let voted = false, turn = 0, lastHolderSince = null, lastBeat = 0, matchId = null;
    const started = Date.now();
    let busy = false;
    let finished = false;

    async function doTurn(turnNo, holderSince) {
        const steps = plan.turn(turnNo);
        const turnStart = Date.now();
        for (const [kind, arg] of steps) {
            const [L] = await q("select holder_player_id, holder_since, phase, current_song_id, current_attempt_id from lobbies where id = $1", [lobbyId]);
            if (L.phase !== "running" || L.holder_player_id !== me || String(L.holder_since) !== String(holderSince)) return;
            if (kind === "wait") { await sleep(arg); continue; }
            if (kind === "explode") { say(`   Zug ${turnNo}: Claude tippt nichts mehr und lässt die Kartoffel explodieren 💥`); log.push({ turn: turnNo, input: null, result: "explode" }); return; }
            const [song] = await q("select title, artist from song_pool where id = $1", [L.current_song_id]);
            let text = arg;
            if (kind === "title") text = song.title;
            if (kind === "title-lower") text = song.title.toLowerCase().replace(/[^\p{L}\p{N} ]+/gu, " ").replace(/\s+/g, " ").trim();
            if (kind === "artist") text = song.artist.split(/\s*,\s*|\s*&\s*|\s+feat\.?\s+/i)[0];
            const [before] = await q("select song_points from players where lobby_id = $1 and player_id = $2", [lobbyId, me]);
            const res = await rpc("rpc_attempt_pass", { p_code: code, p_player_id: me, p_answer: text });
            const [after] = await q("select song_points from players where lobby_id = $1 and player_id = $2", [lobbyId, me]);
            const diff = Number(after.song_points) - Number(before.song_points);
            const t = ((Date.now() - turnStart) / 1000).toFixed(1).replace(".", ",");
            let result;
            if (res.error) result = `Fehler: ${res.error}`;
            else if (res.data == null) result = "wrong";
            else result = diff >= 1 ? "title" : diff > 0 ? "artist" : "accepted?";
            const label = { wrong: "❌ falsch", title: "✅ Titel (+1)", artist: "🟡 Interpret (+½)" }[result] ?? result;
            say(`   Zug ${turnNo} · ${t} s · Claude tippt: "${text}"  → ${label}   (Song: ${song.artist} – ${song.title})`);
            log.push({ turn: turnNo, input: text, kind, result, song: `${song.artist} – ${song.title}` });
            if (result === "title" || result === "artist") return;
        }
    }

    while (!finished) {
        if (Date.now() - started > 8 * 60_000) throw new Error("Zeitüberschreitung im Match");
        const [L] = await q("select * from lobbies where id = $1", [lobbyId]);
        matchId = L.match_id ?? matchId;
        const now = Date.now();
        if (now - lastBeat > 4000) { lastBeat = now; void rpc("rpc_heartbeat", { p_lobby_id: lobbyId, p_player_id: me }); }

        if (L.phase === "topic_vote") {
            if (!voted) {
                voted = true;
                await rpc("rpc_vote_topic", { p_lobby_id: lobbyId, p_player_id: me, p_choice: 1 });
                await rpc("rpc_maybe_shorten_topic_vote", { p_lobby_id: lobbyId });
                say(`Abstimmung: Claude wählt Playlist A (${L.topic_a ?? "?"})`);
            }
            if (L.topic_vote_ends_at && new Date(L.topic_vote_ends_at).getTime() <= now) await rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
        } else if (L.phase === "countdown") {
            if (L.countdown_ends_at && new Date(L.countdown_ends_at).getTime() <= now) await rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });
        } else if (L.phase === "running") {
            if (L.explode_at && new Date(L.explode_at).getTime() - 150 <= now) await rpc("rpc_tick_game", { p_code: code });
            if (L.holder_player_id === me && !busy && String(L.holder_since) !== String(lastHolderSince)) {
                lastHolderSince = L.holder_since;
                turn++;
                busy = true;
                doTurn(turn, L.holder_since).finally(() => (busy = false));
            }
        }
        // Match vorbei, sobald der Konto-Verlauf es eingetragen hat
        if (matchId) {
            const done = await q("select 1 from account_matches where user_id = $1 and match_id = $2", [acc.uid, matchId]);
            if (done.length) finished = true;
        }
        await sleep(250);
    }
    while (busy) await sleep(100);

    const [m] = await q("select place, players_count, total_points, round_wins, title_hits, artist_hits, wrong_guesses, ranked, playlists from account_matches where user_id = $1 and match_id = $2", [acc.uid, matchId]);
    const sr = await q(
        `select p.name, sr.place, sr.arena_points, sr.song_points from series_results sr join players p on p.lobby_id = sr.lobby_id and p.player_id = sr.player_id
         where sr.lobby_id = $1 order by sr.place`,
        [lobbyId]
    );
    say(`Ergebnis: ${sr.map((x) => `${x.place}. ${x.name} (${x.arena_points} P.)`).join(" · ")}`);
    await rpc("rpc_leave_lobby", { p_lobby_id: lobbyId, p_player_id: me });
    return { plan: plan.name, code, matchId, lobbyId, log, match: m, results: sr };
}

// ---------- Erwartung aus den eigenen Eingaben vs. Statistik ----------
async function verify(acc, played) {
    const sb = clientFor(acc.token, randomUUID());
    const { data: stats, error } = await sb.rpc("get_my_profile_stats", { p_season: null });
    if (error) throw new Error("get_my_profile_stats: " + error);
    const checks = [];
    const check = (label, expected, actual) => {
        const ok = JSON.stringify(expected) === JSON.stringify(actual);
        checks.push(ok);
        console.log(`   ${ok ? "✅" : "❌"} ${label}: erwartet ${JSON.stringify(expected)}, Statistik zeigt ${JSON.stringify(actual)}`);
    };
    const all = played.flatMap((p) => p.log);
    const cnt = (k) => all.filter((x) => x.result === k).length;

    console.log("\n📊 Statistik-Prüfung (Konto-Seite /profile → get_my_profile_stats)");
    // Bot-Spiele (weniger als 2 Menschen) zählen bewusst nur als Übung, nicht in Siege/Bestenliste (Migration 075)
    check("Gewertete Matches (Bot-Spiele zählen nicht)", 0, stats.totals.matches);
    check("Übungs-Matches", played.length, stats.totals.practiceMatches);
    check("Titel-Treffer gesamt", cnt("title"), stats.music.titles);
    check("Interpret-Treffer gesamt", cnt("artist"), stats.music.artists);
    check("Falsche Antworten gesamt", cnt("wrong"), stats.music.wrong);

    // Schnellster Titel / Ø-Antwortzeit / beste Combo direkt aus dem Spielprotokoll
    const ids = played.map((p) => p.matchId);
    const [ev] = await q(
        `select min(ms) filter (where kind='title') fastest, round(avg(ms) filter (where kind in ('title','artist'))) avgms, max(combo) filter (where kind='title') combo
         from game_events where user_id = $1 and match_id = any($2::uuid[])`,
        [acc.uid, ids]
    );
    check("Schnellster Titel (ms, Spielprotokoll)", ev.fastest, stats.music.fastestTitleMs);
    check("Ø Antwortzeit (ms, Spielprotokoll)", ev.avgms == null ? null : Number(ev.avgms), stats.music.avgAnswerMs == null ? null : Number(stats.music.avgAnswerMs));
    check("Beste Combo", ev.combo ?? 0, stats.music.bestCombo);

    // Pro Playlist
    for (const p of played) {
        const row = stats.playlists.find((x) => x.playlist === MATCHES.find((m) => m.name === p.plan).playlist);
        const t = p.log.filter((x) => x.result === "title").length, a = p.log.filter((x) => x.result === "artist").length, w = p.log.filter((x) => x.result === "wrong").length;
        const myPlace = p.results.find((x) => x.name === acc.username)?.place;
        check(`Playlist ${row?.playlist ?? "?"}: Runden/Titel/Interpret/falsch/Siege`, [1, t, a, w, myPlace === 1 ? 1 : 0], row ? [row.rounds, row.titles, row.artists, row.wrong, row.wins] : null);
    }

    // Letzte Matches (neueste zuerst)
    const recent = stats.recent.slice(0, played.length).reverse();
    played.forEach((p, i) => {
        const r = recent[i];
        const myRes = p.results.find((x) => x.name === acc.username);
        const t = p.log.filter((x) => x.result === "title").length, a = p.log.filter((x) => x.result === "artist").length, w = p.log.filter((x) => x.result === "wrong").length;
        check(
            `${p.plan}: Platz/Spieler/Bots/Punkte/Titel/Interpret/falsch/gewertet`,
            [myRes.place, p.results.length, p.results.length - 1, myRes.arena_points, t, a, w, false],
            r ? [r.place, r.players_count, r.bots_count, r.total_points, r.title_hits, r.artist_hits, r.wrong_guesses, r.ranked] : null
        );
    });

    // Monats-Rückblick
    check("Monats-Rückblick: Matches", played.length, stats.recap.matches);
    check("Monats-Rückblick: Titel/Interpret/falsch", [cnt("title"), cnt("artist"), cnt("wrong")], [stats.recap.titles, stats.recap.artists, stats.recap.wrong]);
    check("Monats-Rückblick: beste Runde (Punkte)", Math.max(...played.map((p) => p.results.find((x) => x.name === acc.username).arena_points)), stats.recap.bestRoundPoints);
    check("Monats-Rückblick: Saison-Punkte (Bot-Spiele zählen nicht)", null, stats.recap.seasonPoints);

    const bad = checks.filter((x) => !x).length;
    console.log(`\n${bad === 0 ? "✅" : "❌"} ${checks.length - bad} von ${checks.length} Statistik-Werten korrekt.`);
    return { stats, bad };
}

try {
    const acc = await ensureClaude();
    if (process.argv.includes("--account-only")) { console.log("✅ Konto bereit."); await db.end(); process.exit(0); }
    if (process.argv.includes("--reset")) {
        await q("delete from account_matches where user_id = $1", [acc.uid]);
        await q("delete from account_rounds where user_id = $1", [acc.uid]);
        console.log("🧹 Konto-Verlauf von Claude geleert");
    }
    const played = [];
    for (let i = 0; i < MATCHES.length; i++) played.push(await playMatch(acc, MATCHES[i], i));
    const { stats, bad } = await verify(acc, played);
    const out = "db/scripts/data/play-claude-report.json";
    (await import("node:fs")).writeFileSync(out, JSON.stringify({ played, stats }, null, 2));
    console.log(`Bericht: ${out}`);
    process.exitCode = bad ? 1 : 0;
} finally {
    await db.end();
}
