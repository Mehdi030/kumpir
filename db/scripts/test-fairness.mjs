// Fairness-Test beim Weitergeben: spielt als Konto "Claude" mehrere Matches gegen Bots über dieselben
// RPCs wie der Browser und misst bei JEDEM Weitergeben (Server-Zeitstempel), wie viel Zeit der Empfänger
// noch hat. Claude gibt dabei teils absichtlich in letzter Sekunde ab ("lastsecond") oder spielt wie ein
// Mensch (Antwortzeit wie echte Spieler aus game_events, "human").
//
//   node db/scripts/test-fairness.mjs            (5 Matches, Bericht in db/scripts/data/fairness-report.json)
//   node db/scripts/test-fairness.mjs --quick    (2 Matches)
import { createClient } from "@supabase/supabase-js";
import { readFileSync, writeFileSync } from "node:fs";
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const db = new pg.Client({ host: dbe.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: dbe.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
const q = async (sql, args = []) => (await db.query(sql, args)).rows;

function clientFor(token, session) {
    return createClient(URL_, ANON, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: `Bearer ${token}`, "x-kumpir-session": session } },
    });
}

async function login() {
    if (!dbe.CLAUDE_TEST_EMAIL) throw new Error("Testkonto fehlt – erst node db/scripts/play-claude.mjs --account-only");
    const t = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
        method: "POST",
        headers: { apikey: ANON, "Content-Type": "application/json" },
        body: JSON.stringify({ email: dbe.CLAUDE_TEST_EMAIL, password: dbe.CLAUDE_TEST_PASSWORD }),
    });
    const tok = await t.json();
    if (!tok.access_token) throw new Error("Anmeldung fehlgeschlagen");
    const [p] = await q("select display_name from profiles where id = $1", [tok.user.id]);
    return { uid: tok.user.id, token: tok.access_token, username: p.display_name };
}

// Antwortzeit echter Spieler (richtige Titel/Interpreten) aus dem Spielprotokoll -> "human"-Strategie zieht daraus
// (ohne das Testkonto selbst, sonst verfälschen frühere Testläufe die Werte)
const humanMs = (
    await q(
        "select ge.ms from game_events ge left join auth.users u on u.id = ge.user_id where not ge.is_bot and ge.kind in ('title','artist') and ge.ms is not null and coalesce(u.email, '') <> $1 order by ge.ms",
        [dbe.CLAUDE_TEST_EMAIL ?? ""]
    )
).map((r) => r.ms);
const pickHuman = () => (humanMs.length ? humanMs[Math.floor(Math.random() * humanMs.length)] : 5500);

const PLAYLIST = "Deutschrap aktuell";
const MATCHES = [
    { name: "Standard, 3 Bots, Claude gibt in letzter Sekunde ab", speed: "normal", bots: [2, 2, 2], strat: "lastsecond" },
    { name: "Blitz, 3 schnelle Bots, letzte Sekunde", speed: "fast", bots: [3, 3, 2], strat: "lastsecond" },
    { name: "Duell gegen 1 Bot, letzte Sekunde", speed: "normal", bots: [2], strat: "lastsecond" },
    { name: "Casual, 2 Bots, Claude spielt wie ein Mensch", speed: "calm", bots: [1, 2], strat: "human" },
    { name: "Blitz, 5 Bots, Claude spielt wie ein Mensch", speed: "fast", bots: [1, 2, 3, 2, 1], strat: "human" },
];

async function playMatch(acc, plan) {
    const session = randomUUID();
    const sb = clientFor(acc.token, session);
    const rpc = async (fn, args) => {
        const { data, error } = await sb.rpc(fn, args);
        return { data, error: error?.message ?? null };
    };
    console.log(`\n🎮 ${plan.name}`);
    let r = await rpc("rpc_create_lobby", { p_host_name: acc.username, p_privacy: "private", p_max_players: 8, p_round_seconds: 25, p_user_id: acc.uid, p_round_speed: plan.speed });
    if (r.error) throw new Error("create: " + r.error);
    const row = Array.isArray(r.data) ? r.data[0] : r.data;
    const code = row.code, me = row.host_player_id;
    r = await rpc("rpc_join_lobby", { p_code: code, p_player_id: me, p_name: acc.username, p_user_id: acc.uid });
    if (r.error) throw new Error("join: " + r.error);
    const { data: lob } = await sb.from("lobbies").select("id").eq("code", code).single();
    const lobbyId = lob.id;
    await rpc("set_lobby_topic_filter", { p_lobby_id: lobbyId, p_me_player_id: me, p_categories: [PLAYLIST] });
    const botNames = ["Bot Anna", "Bot Ben", "Bot Cleo", "Bot Dino", "Bot Emma"];
    for (let i = 0; i < plan.bots.length; i++) {
        r = await rpc("rpc_add_bot", { p_lobby_id: lobbyId, p_me_player_id: me, p_bot_name: botNames[i], p_skill: plan.bots[i] });
        if (r.error) throw new Error("bot: " + r.error);
    }
    r = await rpc("rpc_begin_topic_vote", { p_lobby_id: lobbyId, p_player_id: me });
    if (r.error) throw new Error("start: " + r.error);

    const names = Object.fromEntries((await q("select player_id, name from players where lobby_id = $1", [lobbyId])).map((x) => [x.player_id, x.name]));
    const passes = [];
    const rounds = [];
    const overtimeChecks = [];
    let prev = null, voted = false, busy = false, lastBeat = 0, matchId = null, finished = false, handled = null;
    const started = Date.now();

    async function myTurn(L) {
        // Claude hat die Kumpir: Antwort vorbereiten
        const left = new Date(L.explode_at).getTime() - Date.now();
        let wait;
        if (plan.strat === "lastsecond") wait = Math.max(300, left - 700);
        else wait = pickHuman();
        if (wait >= left - 150) return; // schafft es nicht -> explodiert
        await sleep(wait);
        const [N] = await q("select holder_player_id, holder_since, phase, current_song_id, grace_count from lobbies where id = $1", [lobbyId]);
        if (N.phase !== "running" || N.holder_player_id !== me || String(N.holder_since) !== String(L.holder_since)) return;
        const [song] = await q("select title, artist from song_pool where id = $1", [N.current_song_id]);
        // Nachspielzeit (094): der Interpret allein muss abgelehnt werden
        if (N.grace_count > 0 && overtimeChecks.length < 3) {
            const res = await rpc("rpc_attempt_pass", { p_code: code, p_player_id: me, p_answer: song.artist.split(/\s*,\s*|\s*&\s*/)[0] });
            overtimeChecks.push(res.error?.includes("overtime_title_only") ? "abgelehnt" : `NICHT abgelehnt (${res.error ?? "angenommen"})`);
            if (!res.error) return;
        }
        await rpc("rpc_attempt_pass", { p_code: code, p_player_id: me, p_answer: song.title });
    }

    while (!finished) {
        if (Date.now() - started > 10 * 60_000) throw new Error("Zeitüberschreitung im Match");
        const [L] = await q(
            `select l.*, (select count(*) from players p where p.lobby_id = l.id and p.status = 'active' and p.is_alive)::int alive from lobbies l where l.id = $1`,
            [lobbyId]
        );
        matchId = L.match_id ?? matchId;
        const now = Date.now();
        if (now - lastBeat > 4000) { lastBeat = now; void rpc("rpc_heartbeat", { p_lobby_id: lobbyId, p_player_id: me }); }

        // Messung: Halterwechsel innerhalb derselben Runde = Weitergeben
        if (L.phase === "running" && L.holder_player_id) {
            const key = `${L.series_index}/${L.round_number}`;
            if (prev && prev.key === key && String(prev.holder_since) !== String(L.holder_since)) {
                const at = new Date(L.holder_since).getTime();
                passes.push({
                    round: key, alive: L.alive, speed: plan.speed,
                    from: names[prev.holder] ?? "?", to: names[L.holder_player_id] ?? "?",
                    passerLeft: +((new Date(prev.explode_at).getTime() - at) / 1000).toFixed(2),
                    receiverHas: +((new Date(L.explode_at).getTime() - at) / 1000).toFixed(2),
                    grace: Number(L.last_grace_sec),
                });
            }
            if (!prev || prev.key !== key) rounds.push({ round: key, alive: L.alive, fuse: +((new Date(L.explode_at).getTime() - new Date(L.holder_since).getTime()) / 1000).toFixed(2) });
            prev = { key, holder: L.holder_player_id, holder_since: L.holder_since, explode_at: L.explode_at };
        }

        if (L.phase === "topic_vote") {
            if (!voted) { voted = true; await rpc("rpc_vote_topic", { p_lobby_id: lobbyId, p_player_id: me, p_choice: 1 }); await rpc("rpc_maybe_shorten_topic_vote", { p_lobby_id: lobbyId }); }
            if (L.topic_vote_ends_at && new Date(L.topic_vote_ends_at).getTime() <= now) await rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
        } else if (L.phase === "countdown") {
            if (L.countdown_ends_at && new Date(L.countdown_ends_at).getTime() <= now) await rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });
        } else if (L.phase === "running") {
            if (L.explode_at && new Date(L.explode_at).getTime() - 150 <= now) await rpc("rpc_tick_game", { p_code: code });
            if (L.holder_player_id === me && !busy && String(L.holder_since) !== String(handled)) {
                handled = L.holder_since;
                busy = true;
                myTurn(L).finally(() => (busy = false));
            }
        }
        if (matchId) {
            const done = await q("select 1 from account_matches where user_id = $1 and match_id = $2", [acc.uid, matchId]);
            if (done.length) finished = true;
        }
        await sleep(120);
    }
    while (busy) await sleep(100);

    // Explosionen: wie lange hatte der Geplatzte die Kumpir?
    const boom = await q(
        `select ge.series_index || '/' || ge.round_number as round, p.name, ge.ms, ge.alive_count from game_events ge join players p on p.lobby_id = ge.lobby_id and p.player_id = ge.player_id
         where ge.lobby_id = $1 and ge.match_id = $2 and ge.kind = 'exploded' order by ge.id`,
        [lobbyId, matchId]
    );
    const tempo = await q("select name, tempo_pass_count t, clutch_pass_count c from players where lobby_id = $1 order by seat_index", [lobbyId]);
    await rpc("rpc_leave_lobby", { p_lobby_id: lobbyId, p_player_id: me });
    const g = passes.filter((p) => p.grace > 0).length;
    console.log(`   ${passes.length} Mal weitergegeben, davon ${g}× mit Schutzzeit · ${boom.length} Explosionen`);
    for (const b of boom) console.log(`   💥 Runde ${b.round}: ${b.name} hatte die Kumpir ${(b.ms / 1000).toFixed(1)} s (${b.alive_count} noch drin)`);
    if (overtimeChecks.length) console.log(`   ⏱️ Nachspielzeit, nur Interpret getippt: ${overtimeChecks.join(", ")}`);
    console.log(`   ⚡ Tempo-Abgaben (letzte Runde): ${tempo.map((x) => `${x.name} ${x.t}`).join(" · ")}`);
    return { plan: plan.name, speed: plan.speed, strat: plan.strat, passes, rounds, overtimeChecks, explosions: boom.map((b) => ({ ...b, s: b.ms / 1000 })) };
}

const pct = (arr, p) => {
    if (!arr.length) return null;
    const s = [...arr].sort((a, b) => a - b);
    return +s[Math.min(s.length - 1, Math.floor(p * s.length))].toFixed(2);
};

try {
    const acc = await login();
    const list = process.argv.includes("--quick") ? MATCHES.slice(0, 2) : MATCHES;
    const played = [];
    for (const m of list) played.push(await playMatch(acc, m));

    const all = played.flatMap((p) => p.passes);
    const recv = all.map((p) => p.receiverHas);
    const lastSec = all.filter((p) => p.passerLeft < 1.5);
    const booms = played.flatMap((p) => p.explosions);
    const summary = {
        weitergaben: all.length,
        mitSchutzzeit: all.filter((p) => p.grace > 0).length,
        empfaengerZeit: { min: pct(recv, 0), p10: pct(recv, 0.1), median: pct(recv, 0.5) },
        abgabenInLetzterSekunde: lastSec.length,
        empfaengerNachLetzterSekunde: { min: pct(lastSec.map((p) => p.receiverHas), 0), median: pct(lastSec.map((p) => p.receiverHas), 0.5) },
        explosionen: booms.length,
        explosionenUnter4s: booms.filter((b) => b.s < 4).length,
        explosionenUnter6s: booms.filter((b) => b.s < 6).length,
        laengsteKette: Math.max(0, ...played.flatMap((p) => Object.values(p.passes.reduce((m, x) => ((m[x.round] = (m[x.round] ?? 0) + (x.grace > 0 ? 1 : 0)), m), {})))),
        nachspielzeitInterpretAbgelehnt: played.flatMap((p) => p.overtimeChecks).join(", ") || "nicht vorgekommen",
        menschAntwortzeit: { n: humanMs.length, median: pct(humanMs.map((x) => x / 1000), 0.5), p75: pct(humanMs.map((x) => x / 1000), 0.75), p90: pct(humanMs.map((x) => x / 1000), 0.9) },
        menschenSchaffenIn: Object.fromEntries([4, 5, 6, 7, 8, 10].map((s) => [`${s}s`, humanMs.length ? Math.round((100 * humanMs.filter((x) => x <= s * 1000).length) / humanMs.length) + "%" : null])),
    };
    console.log("\n📊 Zusammenfassung\n" + JSON.stringify(summary, null, 2));
    writeFileSync("db/scripts/data/fairness-report.json", JSON.stringify({ summary, played }, null, 2));
    console.log("Bericht: db/scripts/data/fairness-report.json");
} finally {
    await db.end();
}
