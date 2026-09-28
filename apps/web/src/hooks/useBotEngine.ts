"use client";

import { useEffect, useRef } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { pickBotAnswer } from "@/lib/botAnswers";

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
    current_attempt_id: string | null;
    used_answers: string[] | null;
    round_number: number | null;
};

/**
 * Überlebenswahrscheinlichkeit eines Bots als Halter, abhängig von der
 * Runde: die ersten beiden Runden überleben Bots garantiert (100%),
 * danach sinkt die Chance auf eine gültige Antwort schrittweise, nie
 * unter 15% (sonst wäre Practice-Mode ab Runde 6 unspielbar hart).
 */
function botSurvivalChance(roundNumber: number): number {
    if (roundNumber <= 2) return 1;
    return Math.max(0.15, 1 - (roundNumber - 2) * 0.2);
}

type Attempt = {
    id: string;
    holder_player_id: string;
    status: string;
};

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
            const roundSig = (lobby.topic_a ?? "") + "|" + (lobby.topic_b ?? "");
            bots.forEach((bot) => {
                if (seenVoteRoundsRef.current.get(bot.player_id) === roundSig) return;
                seenVoteRoundsRef.current.set(bot.player_id, roundSig);

                // Random delay 800-2400ms, dann random vote
                const delay = 800 + Math.random() * 1600;
                window.setTimeout(() => {
                    const choice = (Math.floor(Math.random() * 3) + 1) as 1 | 2 | 3;
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

            window.setTimeout(() => {
                if (willSucceed) {
                    const answer = pickBotAnswer(
                        lobby.topic_selected ?? lobby.topic_a,
                        lobby.used_answers ?? []
                    );
                    void supabase.rpc("rpc_attempt_pass", {
                        p_code: lobby.code,
                        p_player_id: holder.player_id,
                        p_answer: answer,
                    });
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
                    void supabase.rpc("rpc_attempt_pass", {
                        p_code: lobby.code,
                        p_player_id: holder.player_id,
                        p_answer: dup,
                    });
                }
            }, delay);
            return;
        }

        // Offener Attempt → alle anderen lebenden Bots stimmen ab
        if (currentAttempt && currentAttempt.status === "pending" && lobby.current_attempt_id) {
            if (seenAttemptIds.current.has(currentAttempt.id)) return;
            seenAttemptIds.current.add(currentAttempt.id);

            bots
                .filter((b) =>
                    b.player_id !== currentAttempt.holder_player_id &&
                    b.is_alive !== false &&
                    b.player_id !== mePlayerId
                )
                .forEach((bot, idx) => {
                    const delay = 600 + idx * 250 + Math.random() * 800;
                    window.setTimeout(() => {
                        // 90% akzeptieren — pragmatisch, Bots sollen das Spiel nicht blockieren
                        const accept = Math.random() < 0.9;
                        void supabase.rpc("rpc_vote_answer", {
                            p_attempt_id: currentAttempt.id,
                            p_voter_id: bot.player_id,
                            p_accept: accept,
                        });
                    }, delay);
                });
        }
    }, [isHost, lobby, players, mePlayerId, currentAttempt, supabase]);
}
