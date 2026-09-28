#!/usr/bin/env node
/**
 * Read-only Spectator: hängt sich an ein LAUFENDES Match (per Lobby-Code)
 * und protokolliert jede Halter-Übernahme + jeden Antwort-Versuch mit
 * Zeitstempel, um pro Runde/Spieler nachzuvollziehen:
 *   - wie lange der Halter bis zu seiner Antwort gebraucht hat
 *   - in welcher Runde jeder Spieler eliminiert wurde
 *
 * Greift NICHT ins Spiel ein (keine RPC-Calls außer lesenden SELECTs) --
 * das Match muss von woanders (z.B. einem echten Browser-Tab mit
 * useBotEngine) tatsächlich angetrieben werden.
 *
 * Aufruf:
 *   node apps/web/scripts/spectate-match.mjs CODE
 */
import { readFileSync, writeFileSync } from "node:fs";
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
const sb = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_ANON_KEY);

const code = (process.argv[2] || "").toUpperCase();
if (!code) {
    console.error("Aufruf: node spectate-match.mjs CODE");
    process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const events = [];
const seenAttempts = new Set();
let names = new Map();
let holderSince = null;
let currentHolder = null;
let currentRound = null;

async function loadNames(lobbyId) {
    const { data } = await sb.from("players").select("player_id,name,is_bot").eq("lobby_id", lobbyId);
    for (const p of data ?? []) names.set(p.player_id, p.name);
}

function nm(id) {
    return names.get(id) ?? id?.slice(0, 8) ?? "?";
}

async function main() {
    const { data: lobby0, error } = await sb.from("lobbies").select("id").eq("code", code).single();
    if (error || !lobby0) {
        console.error("Lobby nicht gefunden:", error?.message);
        process.exit(1);
    }
    const lobbyId = lobby0.id;
    await loadNames(lobbyId);

    console.log(`Spectating ${code} (${lobbyId})...`);

    let lastPhase = null;
    const startedAt = Date.now();

    while (Date.now() - startedAt < 6 * 60 * 1000) {
        const { data: lobby } = await sb
            .from("lobbies")
            .select("phase,holder_player_id,round_number,last_loser_player_id,explode_at,topic_selected")
            .eq("id", lobbyId)
            .single();

        if (!lobby) break;

        if (lobby.phase !== lastPhase) {
            events.push({ t: Date.now(), kind: "phase", phase: lobby.phase });
            lastPhase = lobby.phase;
        }

        if (lobby.phase === "running") {
            if (lobby.round_number !== currentRound) {
                currentRound = lobby.round_number;
            }
            if (lobby.holder_player_id !== currentHolder) {
                if (currentHolder) {
                    const heldMs = Date.now() - holderSince;
                    events.push({
                        t: Date.now(),
                        kind: "holder_change",
                        round: currentRound,
                        from: currentHolder,
                        fromName: nm(currentHolder),
                        heldMs,
                    });
                }
                currentHolder = lobby.holder_player_id;
                holderSince = Date.now();
                events.push({ t: Date.now(), kind: "holder_start", round: currentRound, player: currentHolder, playerName: nm(currentHolder) });
            }
        }

        // Neue pass_attempts einsammeln (Antwort-Versuche mit Zeitstempel)
        const { data: attempts } = await sb
            .from("pass_attempts")
            .select("id,round_number,holder_player_id,answer,status,created_at,decided_at")
            .eq("lobby_id", lobbyId)
            .order("created_at", { ascending: true });

        for (const a of attempts ?? []) {
            if (seenAttempts.has(a.id)) continue;
            seenAttempts.add(a.id);
            events.push({
                t: Date.now(),
                kind: "attempt",
                round: a.round_number,
                player: a.holder_player_id,
                playerName: nm(a.holder_player_id),
                answer: a.answer,
                status: a.status,
                createdAt: a.created_at,
                decidedAt: a.decided_at,
            });
        }

        if (lobby.phase === "finished") {
            events.push({ t: Date.now(), kind: "finished", winner: lobby.holder_player_id, winnerName: nm(lobby.holder_player_id) });
            break;
        }

        await sleep(400);
    }

    writeFileSync(
        resolve(__dirname, "..", "spectate-log.json"),
        JSON.stringify({ code, names: Object.fromEntries(names), events }, null, 2)
    );
    console.log(`Fertig. ${events.length} Events geloggt -> apps/web/spectate-log.json`);
}

main();
