#!/usr/bin/env node
/**
 * Simulator: spielt komplette Matches mit 3-8 Spielern automatisiert durch
 * (Lobby -> Topic-Vote -> Countdown -> Running -> Finished) UND versucht bei
 * jedem Schritt jeden bekannten Cheat -- jetzt mit korrekten Session-Tokens
 * pro simuliertem Spieler, um zu verifizieren, dass Migration 023/024 sie
 * wirklich blockt (nicht nur "sollte laut Code").
 *
 * Jeder simulierte Spieler bekommt seinen EIGENEN Supabase-Client mit
 * seinem EIGENEN x-kumpir-session Header -- genau wie im echten Browser
 * (ein Client = ein Token). Cheat-Versuche nutzen bewusst den Client eines
 * ANDEREN Spielers mit einer FREMDEN player_id als Parameter.
 *
 * Aufruf:
 *   node apps/web/scripts/simulate-match.mjs             # 3..8 Spieler nacheinander
 *   node apps/web/scripts/simulate-match.mjs 5           # nur 5 Spieler
 */

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ENV_PATH = resolve(__dirname, "..", ".env.local");

function parseEnv(text) {
    const map = {};
    for (const raw of text.split(/\r?\n/)) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const i = line.indexOf("=");
        if (i < 0) continue;
        map[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
    return map;
}

const env = parseEnv(readFileSync(ENV_PATH, "utf8"));
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const ANON = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
if (!URL || !ANON) {
    console.error("NEXT_PUBLIC_SUPABASE_URL / _ANON_KEY fehlen in .env.local");
    process.exit(1);
}

const uuid = () => crypto.randomUUID();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function clientFor(token) {
    return createClient(URL, ANON, {
        auth: { persistSession: false },
        global: { headers: token ? { "x-kumpir-session": token } : {} },
    });
}

let pass = 0;
let fail = 0;
const failures = [];
function check(ok, label, detail) {
    if (ok) {
        pass++;
        console.log(`  ✅ ${label}`);
    } else {
        fail++;
        failures.push(`${label}${detail ? ` — ${detail}` : ""}`);
        console.log(`  ❌ ${label}${detail ? ` — ${detail}` : ""}`);
    }
}

/** Baut eine Lobby mit N Spielern auf, jeder mit eigenem Client+Token. */
async function makeLobby(n, speed = "fast") {
    const host = { token: uuid() };
    host.client = clientFor(host.token);

    const { data, error } = await host.client.rpc("rpc_create_lobby", {
        p_host_name: "Host",
        p_privacy: "private",
        p_max_players: 12,
        p_round_seconds: 25,
        p_user_id: null,
        p_round_speed: speed,
    });
    if (error) throw new Error(`rpc_create_lobby: ${error.message}`);
    const row = Array.isArray(data) ? data[0] : data;
    const code = String(row.code).toUpperCase();
    host.id = String(row.host_player_id);

    await host.client.rpc("rpc_join_lobby", { p_code: code, p_player_id: host.id, p_name: "Host", p_user_id: null });

    const players = [host];
    for (let i = 1; i < n; i++) {
        const token = uuid();
        const client = clientFor(token);
        const id = uuid();
        const { error: joinErr } = await client.rpc("rpc_join_lobby", {
            p_code: code, p_player_id: id, p_name: `P${i}`, p_user_id: null,
        });
        if (joinErr) throw new Error(`join P${i}: ${joinErr.message}`);
        players.push({ token, client, id });
    }

    const { data: lob } = await host.client.from("lobbies").select("id").eq("code", code).single();
    return { code, lobbyId: lob.id, players, host };
}

async function readLobby(host, lobbyId) {
    const { data } = await host.client.from("lobbies").select("*").eq("id", lobbyId).single();
    return data;
}

async function readAlivePlayers(host, lobbyId) {
    const { data } = await host.client.from("players").select("player_id,is_alive,status").eq("lobby_id", lobbyId).eq("status", "active");
    return data ?? [];
}

/** Voller Match-Durchlauf bis 'finished'. Gibt Runden-Statistik zurück. */
async function playMatch(n, speed) {
    console.log(`\n${"=".repeat(60)}\n🎮 Match mit ${n} Spielern (Speed: ${speed})\n${"=".repeat(60)}`);
    const { code, lobbyId, players, host } = await makeLobby(n, speed);
    console.log(`   Lobby ${code} erstellt, ${n} Spieler beigetreten`);

    // Alle ready
    for (const p of players) {
        const r = await p.client.rpc("rpc_toggle_ready", { p_lobby_id: lobbyId, p_player_id: p.id });
        check(!r.error, `Spieler ${p.id.slice(0, 8)} kann sich selbst ready setzen`, r.error?.message);
    }

    // Spiel starten (Host)
    const begin = await host.client.rpc("rpc_begin_topic_vote", { p_lobby_id: lobbyId, p_player_id: host.id });
    check(!begin.error, "Host startet Topic-Vote", begin.error?.message);
    if (begin.error) return null;

    // Alle stimmen ab
    for (const p of players) {
        const choice = 1 + Math.floor(Math.random() * 2);
        const v = await p.client.rpc("rpc_vote_topic", { p_lobby_id: lobbyId, p_player_id: p.id, p_choice: choice });
        if (v.error) check(false, `Spieler stimmt bei Topic ab`, v.error.message);
    }
    await host.client.rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
    await host.client.rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });

    let lob = await readLobby(host, lobbyId);
    check(lob.phase === "running", "Phase erreicht 'running'", `ist ${lob.phase}`);
    if (lob.phase !== "running") return null;

    // Runden spielen bis nur noch 1 übrig ist. Zeit-basiertes Limit statt
    // Tick-Zähler: Eliminationen hängen an echten Timestamps (explode_at),
    // ein Tick-Limit hätte bei "calm"-Speed (bis 40s/Runde) nie gereicht.
    let rounds = 0;
    let passes = 0;
    const startedAt = Date.now();
    const maxWallClockMs = 5 * 60 * 1000;
    while (Date.now() - startedAt < maxWallClockMs) {
        lob = await readLobby(host, lobbyId);
        if (lob.phase === "finished") break;
        if (lob.phase !== "running") { await sleep(150); rounds++; continue; }

        const alive = await readAlivePlayers(host, lobbyId);
        const holderRow = players.find((p) => p.id === lob.holder_player_id);

        // Timer abgelaufen? Jeder lebende Client prüft mit (wie im echten Client).
        if (lob.explode_at && Date.now() >= Date.parse(lob.explode_at) - 100) {
            await host.client.rpc("rpc_tick_game", { p_code: code });
            await sleep(200);
            rounds++;
            continue;
        }

        if (!lob.current_attempt_id && holderRow) {
            const answer = `Antwort-${rounds}-${passes}`;
            const a = await holderRow.client.rpc("rpc_attempt_pass", { p_code: code, p_player_id: holderRow.id, p_answer: answer });
            if (a.error) { await sleep(250); rounds++; continue; }

            lob = await readLobby(host, lobbyId);
            const attemptId = lob.current_attempt_id;
            if (attemptId) {
                for (const voter of players) {
                    if (voter.id === holderRow.id) continue;
                    if (!alive.some((a2) => a2.player_id === voter.id && a2.is_alive)) continue;
                    await voter.client.rpc("rpc_vote_answer", { p_attempt_id: attemptId, p_voter_id: voter.id, p_accept: true });
                }
                passes++;
            }
        }
        await sleep(300);
        rounds++;
    }

    lob = await readLobby(host, lobbyId);
    const finished = lob.phase === "finished";
    check(finished, `Match beendet (phase='finished')`, `nach ${rounds} Ticks, ist ${lob.phase}`);

    if (finished) {
        // Rematch-Flow
        const rm = await host.client.rpc("rpc_rematch", { p_code: code, p_player_id: host.id });
        check(!rm.error, "Rematch als Mitglied möglich", rm.error?.message);
    }

    console.log(`   ${passes} erfolgreiche Pässe über ${rounds} Ticks · Ergebnis: phase=${lob.phase}`);
    return { code, lobbyId, players, host };
}

/** Cheat-Versuche NACH den Fixes -- müssen alle BLOCKED sein. */
async function cheatAttempts(ctx) {
    if (!ctx) return;
    const { code, lobbyId, players, host } = ctx;
    const attacker = players[players.length - 1];
    const victim = players[Math.floor(players.length / 2)] ?? players[0];

    console.log(`\n── Cheat-Versuche mit echten (aber falschen) Tokens ──`);

    // 1. Fremdes Ready-Toggle
    const r1 = await attacker.client.rpc("rpc_toggle_ready", { p_lobby_id: lobbyId, p_player_id: victim.id });
    check(!!r1.error, "Ready-Toggle für fremde ID blockiert", r1.error ? undefined : "ging durch!");

    // 2. Host-Aktion mit korrekter Host-ID aber Angreifer-Token
    const spoofClient = clientFor(attacker.token);
    const k = await spoofClient.rpc("kick_player", { p_lobby_id: lobbyId, p_me_player_id: host.id, p_target_player_id: victim.id });
    check(!!k.error, "kick_player mit korrekter Host-ID aber fremdem Token blockiert", k.error ? undefined : "ging durch!");

    // 3. Vote-Stuffing: Angreifer stimmt für alle anderen ab (mit deren IDs, aber seinem Token)
    // Dafür zuerst einen Attempt provozieren, falls Runde noch läuft
    const lob = await readLobby(host, lobbyId);
    if (lob.phase === "running" && lob.current_attempt_id) {
        let stuffed = 0;
        for (const p of players) {
            if (p.id === lob.holder_player_id || p.id === attacker.id) continue;
            const v = await attacker.client.rpc("rpc_vote_answer", { p_attempt_id: lob.current_attempt_id, p_voter_id: p.id, p_accept: true });
            if (!v.error) stuffed++;
        }
        check(stuffed === 0, "Vote-Stuffing (fremde Stimmen über einen Client) blockiert", stuffed > 0 ? `${stuffed} fremde Stimmen durchgekommen` : undefined);
    } else {
        console.log("  ⏭  Vote-Stuffing-Test übersprungen (kein offener Attempt gerade)");
    }

    // 4. rpc_reset_lobby als Aussenstehender (ganz ohne echten Client der Lobby)
    const outsider = clientFor(uuid());
    const r2 = await outsider.rpc("rpc_reset_lobby", { p_code: code, p_player_id: uuid() });
    check(!!r2.error, "rpc_reset_lobby als Aussenstehender blockiert", r2.error ? undefined : "ging durch!");

    // 5. Direkter Tabellenzugriff bleibt blockiert (RLS, unabhängig von Token)
    const w = await attacker.client.from("players").update({ is_alive: true }).eq("lobby_id", lobbyId).eq("player_id", victim.id).select();
    check(!w.data || w.data.length === 0, "Direktes UPDATE auf players weiterhin blockiert (RLS)", w.error ? undefined : `${w.data?.length ?? 0} Zeilen geändert`);

    // 6. PII weiterhin gesperrt
    const e = await attacker.client.rpc("get_email_for_username", { p_username: "test" });
    check(!!e.error, "get_email_for_username weiterhin gesperrt", e.error ? undefined : "ging durch!");
}

async function main() {
    const arg = process.argv[2];
    const counts = arg ? [Number(arg)] : [3, 4, 5, 6, 7, 8];
    const speeds = ["fast", "normal", "calm"];

    for (const n of counts) {
        const speed = speeds[n % speeds.length];
        try {
            const ctx = await playMatch(n, speed);
            await cheatAttempts(ctx);
        } catch (e) {
            fail++;
            failures.push(`Match n=${n}: ${e.message}`);
            console.log(`  💥 Match n=${n} abgebrochen: ${e.message}`);
        }
    }

    console.log(`\n${"=".repeat(60)}`);
    console.log(`   ${pass} bestanden · ${fail} fehlgeschlagen`);
    if (failures.length) {
        console.log("\n❌ Fehlgeschlagene Prüfungen:");
        for (const f of failures) console.log(`   • ${f}`);
    }
    process.exit(fail ? 1 : 0);
}

main().catch((e) => {
    console.error("Simulation abgebrochen:", e.message);
    process.exit(2);
});
