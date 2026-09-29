"use client";

import { useEffect, useRef } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { pickBotAnswer, BOT_FALLBACK } from "@/lib/botAnswers";

type Player = {
    player_id: string;
    name: string;
    is_alive?: boolean;
    is_bot?: boolean;
    ready?: boolean | null;
    status?: string;
};

type LobbyForBot = {
    id: string;
    code: string;
    phase: string;
    host_player_id: string | null;
    holder_player_id: string | null;
    topic_selected: string | null;
    topic_a: string | null;
    topic_b: string | null;
    topic_c: string | null;
    current_attempt_id: string | null;
    used_answers: string[] | null;
    round_number: number | null;
    current_song_id: string | null;
};

/**
 * Überlebenswahrscheinlichkeit eines Bots als Halter, abhängig von der
 * Runde: Runde 1 fast garantiert richtig, danach sinkt es in klaren
 * Stufen (2: 60%, 3: 40%, 4: 20%), danach weiter gemächlich abwärts,
 * nie unter 10% (sonst wäre Practice-Mode ab Runde 6 unspielbar hart).
 */
function botSurvivalChance(roundNumber: number): number {
    if (roundNumber <= 1) return 0.9;
    if (roundNumber === 2) return 0.6;
    if (roundNumber === 3) return 0.4;
    if (roundNumber === 4) return 0.2;
    return Math.max(0.1, 0.2 - (roundNumber - 4) * 0.05);
}

type Attempt = {
    id: string;
    holder_player_id: string;
    status: string;
    answer: string;
};

// Spiegelt exakt den Vergleich aus rpc_attempt_pass (db/functions.sql):
// Klammer-Zusätze wie "(feat. ...)" werden toleriert.
function stripParen(s: string) {
    return s.replace(/\s*\(.*?\)\s*/g, " ").trim();
}
function songAnswerMatches(title: string, answer: string) {
    const t = title.toLowerCase().trim();
    const a = answer.toLowerCase().trim();
    return t === a || stripParen(t) === a;
}

const songTitleCache = new Map<string, string | null>();
const topicPoolIdCache = new Map<string, string | null>();

async function fetchSongTitle(supabase: SupabaseClient, songId: string): Promise<string | null> {
    if (songTitleCache.has(songId)) return songTitleCache.get(songId)!;
    const { data, error } = await supabase.from("song_pool").select("title").eq("id", songId).single();
    const title = !error && data ? (data.title as string) : null;
    songTitleCache.set(songId, title);
    return title;
}

async function fetchTopicPoolId(supabase: SupabaseClient, topicText: string): Promise<string | null> {
    const key = topicText.toLowerCase();
    if (topicPoolIdCache.has(key)) return topicPoolIdCache.get(key)!;
    const { data, error } = await supabase.from("topic_pool").select("id").ilike("text", topicText).limit(1).maybeSingle();
    const id = !error && data ? (data.id as string) : null;
    topicPoolIdCache.set(key, id);
    return id;
}

/**
 * Ermittelt, ob eine abgegebene Antwort wirklich korrekt ist -- dieselbe
 * Prüfung, die auch der Server in rpc_attempt_pass macht (song_pool exakt
 * im Song-Modus, sonst topic_answers). Nur wenn der Server das schon
 * SELBST erkannt hätte, wäre der Versuch nie in den Abstimmungs-Status
 * gekommen -- landet er trotzdem hier, ist er nach dieser Prüfung so gut
 * wie sicher falsch. Für Themen ohne Eintrag in topic_answers (nicht
 * jede gültige Antwort ist katalogisiert) bleibt eine kleine Toleranz,
 * damit Bots nicht jede unbekannte, aber plausible Antwort blind ablehnen.
 */
async function isAnswerActuallyCorrect(
    supabase: SupabaseClient,
    lobby: LobbyForBot,
    attempt: Attempt
): Promise<boolean> {
    if (lobby.current_song_id) {
        const title = await fetchSongTitle(supabase, lobby.current_song_id);
        if (!title) return false;
        return songAnswerMatches(title, attempt.answer);
    }

    const topic = lobby.topic_selected ?? lobby.topic_a ?? "";
    if (!topic) return false;

    const topicPoolId = await fetchTopicPoolId(supabase, topic);
    if (!topicPoolId) return Math.random() < 0.25;

    const { data } = await supabase
        .from("topic_answers")
        .select("id")
        .eq("topic_pool_id", topicPoolId)
        .eq("lower_answer", attempt.answer.trim().toLowerCase())
        .limit(1)
        .maybeSingle();

    if (data) return true;
    // Unbekannt (nicht katalogisiert) -- gelegentlich trotzdem im Zweifel
    // für den Angeklagten, damit kreative aber richtige Antworten nicht
    // systematisch durchfallen.
    return Math.random() < 0.25;
}

/**
 * Bot-Engine. Läuft NUR beim Host — andere Clients sind passiv.
 * Pollt regelmäßig die Lobby + Pass-Attempts und steuert Bots:
 *   - Topic-Vote: Bot wählt zufällig nach kurzer Verzögerung
 *   - Bot ist Halter: schickt rpc_attempt_pass mit zufälliger Antwort
 *   - Offener Attempt + Bot kein Halter: stimmt nach Delay ab (90% ✅)
 *
 * Verhindert Doppel-Aktionen via lastActionRef (eine Bot-Aktion pro Phase-Event).
 */
export function useBotEngine(
    isHost: boolean,
    lobby: LobbyForBot | null,
    players: Player[],
    mePlayerId: string | null,
    currentAttempt: Attempt | null
) {
    const supabase = getSupabaseClient();

    // Verhindert: gleicher Bot reagiert mehrmals auf gleichen Anlass
    const seenAttemptIds = useRef<Set<string>>(new Set());
    const seenVoteRoundsRef = useRef<Map<string, string>>(new Map()); // botId → topic_a (= round signature)
    const seenAttemptStartRef = useRef<string | null>(null);

    useEffect(() => {
        if (!isHost) return;
        if (!lobby) return;

        const bots = players.filter((p) => p.is_bot && p.status === "active");
        if (bots.length === 0) return;

        // === TOPIC VOTE ===
        if (lobby.phase === "topic_vote") {
            const roundSig = (lobby.topic_a ?? "") + "|" + (lobby.topic_b ?? "") + "|" + (lobby.topic_c ?? "");
            bots.forEach((bot) => {
                if (seenVoteRoundsRef.current.get(bot.player_id) === roundSig) return;
                seenVoteRoundsRef.current.set(bot.player_id, roundSig);

                // Random delay 800-2400ms, dann random vote -- "3" nur, wenn
                // es wirklich ein drittes Thema gibt (topic_c), sonst würde
                // der Bot eine nicht angebotene Option wählen.
                const delay = 800 + Math.random() * 1600;
                const maxChoice = lobby.topic_c ? 3 : 2;
                window.setTimeout(() => {
                    const choice = (Math.floor(Math.random() * maxChoice) + 1) as 1 | 2 | 3;
                    void supabase.rpc("rpc_vote_topic", {
                        p_lobby_id: lobby.id,
                        p_player_id: bot.player_id,
                        p_choice: choice,
                    });
                }, delay);
            });
            return;
        }

        // === RUNNING ===
        if (lobby.phase !== "running") return;

        const holder = bots.find((b) => b.player_id === lobby.holder_player_id && b.is_alive !== false);

        // Bot ist Halter und KEIN offener Attempt → tippe Antwort
        if (holder && !lobby.current_attempt_id) {
            const attemptKey = `${lobby.id}|${lobby.holder_player_id}|${(lobby.used_answers ?? []).length}`;
            if (seenAttemptStartRef.current === attemptKey) return;
            seenAttemptStartRef.current = attemptKey;

            const delay = 900 + Math.random() * 1800;
            const roundNumber = lobby.round_number ?? 1;
            const willSucceed = Math.random() < botSurvivalChance(roundNumber);
            const songId = lobby.current_song_id;

            window.setTimeout(() => {
                void (async () => {
                    // Song-Modus: die generische ANSWERS-Liste aus botAnswers.ts
                    // (Kategorie-Titel) hat mit dem tatsächlich gezogenen Song
                    // (song_pool.current_song_id) nichts zu tun -- ein "richtiger"
                    // Bot muss den ECHTEN Titel des aktuellen Songs abschicken,
                    // sonst prüft der Server (rpc_attempt_pass) ihn als falsch,
                    // egal wie die Erfolgs-Quote gewürfelt hat.
                    if (songId) {
                        const realTitle = willSucceed ? await fetchSongTitle(supabase, songId) : null;
                        const answer = realTitle ?? BOT_FALLBACK[Math.floor(Math.random() * BOT_FALLBACK.length)]!;
                        const { error } = await supabase.rpc("rpc_attempt_pass", {
                            p_code: lobby.code,
                            p_player_id: holder.player_id,
                            p_answer: answer,
                        });
                        if (error) console.error("[bot] song attempt failed:", holder.name, error);
                        return;
                    }

                    if (willSucceed) {
                        const answer = pickBotAnswer(
                            lobby.topic_selected ?? lobby.topic_a,
                            lobby.used_answers ?? []
                        );
                        const { error } = await supabase.rpc("rpc_attempt_pass", {
                            p_code: lobby.code,
                            p_player_id: holder.player_id,
                            p_answer: answer,
                        });
                        if (error) console.error("[bot] attempt failed:", holder.name, error);
                        return;
                    }

                    // Ab Runde 3, mit wachsender Wahrscheinlichkeit: der Bot "vergreift"
                    // sich absichtlich (schon benutzte Antwort -> answer_already_used,
                    // es entsteht gar kein Attempt) und riskiert damit die Explosion,
                    // statt garantiert weiterzukommen. Ohne bereits benutzte Antworten
                    // (ganz frühe Runde) bleibt der Bot einfach untätig -- derselbe
                    // Effekt: er hält, bis der Timer über ihn entscheidet.
                    const used = lobby.used_answers ?? [];
                    if (used.length > 0) {
                        const dup = used[Math.floor(Math.random() * used.length)];
                        const { error } = await supabase.rpc("rpc_attempt_pass", {
                            p_code: lobby.code,
                            p_player_id: holder.player_id,
                            p_answer: dup,
                        });
                        if (error) console.error("[bot] deliberate-fail attempt errored:", holder.name, error);
                    }
                })();
            }, delay);
            return;
        }

        // Offener Attempt → alle anderen lebenden Bots stimmen ab -- jetzt
        // anhand einer echten Korrektheitsprüfung (isAnswerActuallyCorrect)
        // statt der alten blinden 90%-Akzeptanz, die falsche Song-Titel
        // praktisch immer durchgewunken hat.
        if (currentAttempt && currentAttempt.status === "pending" && lobby.current_attempt_id) {
            if (seenAttemptIds.current.has(currentAttempt.id)) return;
            seenAttemptIds.current.add(currentAttempt.id);

            const voters = bots.filter((b) =>
                b.player_id !== currentAttempt.holder_player_id &&
                b.is_alive !== false &&
                b.player_id !== mePlayerId
            );
            if (voters.length === 0) return;

            void isAnswerActuallyCorrect(supabase, lobby, currentAttempt).then((correct) => {
                voters.forEach((bot, idx) => {
                    const delay = 600 + idx * 250 + Math.random() * 800;
                    window.setTimeout(() => {
                        supabase
                            .rpc("rpc_vote_answer", {
                                p_attempt_id: currentAttempt.id,
                                p_voter_id: bot.player_id,
                                p_accept: correct,
                            })
                            .then(({ error }) => {
                                if (error) console.error("[bot] vote failed:", bot.name, error);
                            });
                    }, delay);
                });
            });
        }
    }, [isHost, lobby, players, mePlayerId, currentAttempt, supabase]);
}
