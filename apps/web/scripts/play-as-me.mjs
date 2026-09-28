#!/usr/bin/env node
/**
 * Steuert EINEN echten Spieler (mich) im Match genauso wie die eingebaute
 * Bot-Engine ihre Bots steuert -- durchgehendes, schnelles Polling statt
 * einzelner, langsamer Tool-Aufrufe. Löst genau das Problem, das beim
 * manuellen Mitspielen über Browser-Tool-Klicks auftrat: nicht die
 * Reaktionszeit war zu langsam, sondern das Abfrage-Intervall zwischen
 * zwei Tool-Calls war zu grob, um ein kurzes Zeitfenster zuverlässig zu
 * erwischen.
 *
 * Antworten kommen IMMER aus der echten Antwort-Datenbank (topic_answers)
 * bzw. bei Musik-Kategorien aus song_pool -- nie aus einer generischen
 * Fallback-Liste, damit jede Antwort zum Thema passt und sofort per
 * Instant-Accept durchgeht (kein Warten auf Mitspieler-Votes nötig).
 *
 * Nutzt player_id + session_token aus dem echten Browser-localStorage
 * (kumpir_player_id / kumpir_session_token) -- steuert also den
 * TATSÄCHLICHEN Spieler, nicht einen separaten Fake-Account.
 *
 * Aufruf:
 *   node apps/web/scripts/play-as-me.mjs <CODE> <PLAYER_ID> <SESSION_TOKEN> [maxSeconds]
 */
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const env = Object.fromEntries(
    readFileSync(resolve(__dirname, "..", ".env.local"), "utf8")
        .split(/\r?\n/)
        .filter((l) => l.includes("=") && !l.startsWith("#"))
        .map((l) => {
            const i = l.indexOf("=");
            return [l.slice(0, i).trim(), l.slice(i + 1).trim()];
        })
);
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const ANON = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

const [code, playerId, sessionToken, maxSecondsArg] = process.argv.slice(2);
if (!code || !playerId || !sessionToken) {
    console.error("Aufruf: node play-as-me.mjs <CODE> <PLAYER_ID> <SESSION_TOKEN> [maxSeconds]");
    process.exit(1);
}
const maxSeconds = Number(maxSecondsArg || 240);

const client = createClient(URL, ANON, {
    auth: { persistSession: false },
    global: { headers: { "x-kumpir-session": sessionToken } },
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const seenVoteFor = new Set();
const seenAttemptKeys = new Set();
const seenVotedAttempts = new Set();

async function readLobby() {
    const { data } = await client.from("lobbies").select("*").eq("code", code.toUpperCase()).single();
    return data;
}

async function correctAnswerFor(topicText, usedAnswers) {
    const { data: tp } = await client.from("topic_pool").select("id,is_song_category").ilike("text", topicText).maybeSingle();
    if (!tp) return null;
    const used = new Set((usedAnswers ?? []).map((a) => a.toLowerCase()));
    if (tp.is_song_category) return null;
    const { data: answers } = await client.from("topic_answers").select("answer").eq("topic_pool_id", tp.id).limit(200);
    const fresh = (answers ?? []).filter((a) => !used.has(a.answer.toLowerCase()));
    if (fresh.length === 0) return null;
    return fresh[Math.floor(Math.random() * fresh.length)].answer;
}

async function currentSongTitle(songId) {
    const { data } = await client.from("song_pool").select("title").eq("id", songId).maybeSingle();
    return data?.title ?? null;
}

console.log(`Steuere Spieler ${playerId.slice(0, 8)} in Lobby ${code} (bis zu ${maxSeconds}s)...`);
const startedAt = Date.now();

while (Date.now() - startedAt < maxSeconds * 1000) {
    const lobby = await readLobby();
    if (!lobby) { await sleep(300); continue; }

    if (lobby.phase === "finished") {
        console.log("Match beendet.");
        break;
    }

    if (lobby.phase === "topic_vote") {
        const sig = `${lobby.topic_a}|${lobby.topic_b}`;
        if (!seenVoteFor.has(sig)) {
            seenVoteFor.add(sig);
            const { error } = await client.rpc("rpc_vote_topic", { p_lobby_id: lobby.id, p_player_id: playerId, p_choice: 1 });
            console.log(`  Topic-Vote abgegeben (Thema A): ${error ? "FEHLER " + error.message : "ok"}`);
        }
        await sleep(200);
        continue;
    }

    if (lobby.phase !== "running") {
        await sleep(200);
        continue;
    }

    if (lobby.holder_player_id === playerId && !lobby.current_attempt_id) {
        const attemptKey = `${lobby.holder_player_id}|${(lobby.used_answers ?? []).length}`;
        if (!seenAttemptKeys.has(attemptKey)) {
            seenAttemptKeys.add(attemptKey);

            let answer;
            if (lobby.current_song_id) {
                answer = await currentSongTitle(lobby.current_song_id);
            } else {
                answer = await correctAnswerFor(lobby.topic_selected ?? lobby.topic_a, lobby.used_answers);
            }

            if (answer) {
                const { error } = await client.rpc("rpc_attempt_pass", { p_code: code.toUpperCase(), p_player_id: playerId, p_answer: answer });
                console.log(`  [Halter] Antwort "${answer}" -> ${error ? "FEHLER " + error.message : "gesendet"}`);
            } else {
                console.log("  [Halter] Keine passende Antwort in der Datenbank gefunden -- warte.");
            }
        }
        await sleep(150);
        continue;
    }

    if (lobby.current_attempt_id && !seenVotedAttempts.has(lobby.current_attempt_id) && lobby.holder_player_id !== playerId) {
        seenVotedAttempts.add(lobby.current_attempt_id);
        const { error } = await client.rpc("rpc_vote_answer", { p_attempt_id: lobby.current_attempt_id, p_voter_id: playerId, p_accept: true });
        console.log(`  [Vote] fuer Attempt ${lobby.current_attempt_id.slice(0, 8)} -> ${error ? "FEHLER " + error.message : "ok"}`);
    }

    await sleep(150);
}

console.log("Fertig.");
