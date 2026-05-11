"use client";

import { useEffect, useRef } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

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
    last_pass_target_id: string | null;
    last_pass_at: string | null;
    pass_counter: number;
};

/**
 * Bot-Engine — läuft NUR im Host-Browser. Neue „Schnell-Pass"-Mechanik:
 *
 *   - Topic-Vote: zufällige Wahl mit 0.8–2.4s Delay
 *   - Bot ist Halter: nach 1.2–3s direkt `rpc_pass_potato` (Antwort wäre eh mündlich)
 *   - Nach einem Pass: 5% Chance pro Bot, dass er „ermahnt" (selten, fairer Faktor)
 *
 * Race-Schutz: lastPassedRef + lastWarnedRef merken sich pro pass_counter.
 */
export function useBotEngine(
    isHost: boolean,
    lobby: LobbyForBot | null,
    players: Player[],
    mePlayerId: string | null
) {
    const supabase = getSupabaseClient();

    const seenVoteRoundsRef = useRef<Map<string, string>>(new Map());
    const lastPassedRef = useRef<Map<string, number>>(new Map()); // botId → letztes pass_counter
    const warnedRoundsRef = useRef<Set<string>>(new Set()); // "botId:pass_counter"

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

        // Bot ist Halter → nach 1.2–3s direkter Pass (Antwort wird „mündlich" gesagt)
        if (holder) {
            const myLast = lastPassedRef.current.get(holder.player_id) ?? -1;
            if (myLast === lobby.pass_counter) {
                // schon gepasst für dieses pass_counter
                return;
            }
            lastPassedRef.current.set(holder.player_id, lobby.pass_counter);

            const delay = 1200 + Math.random() * 1800;
            window.setTimeout(() => {
                void supabase.rpc("rpc_pass_potato", {
                    p_code: lobby.code,
                    p_player_id: holder.player_id,
                });
            }, delay);
            return;
        }

        // Nicht-Halter-Bots: 5% Chance ermahnen (innerhalb des Pass-Fensters)
        if (lobby.last_pass_target_id && lobby.last_pass_at) {
            const passAtMs = Date.parse(lobby.last_pass_at);
            const windowOk = !Number.isNaN(passAtMs) && Date.now() - passAtMs < 4500; // 4.5s sicher unter 5s
            if (!windowOk) return;

            bots
                .filter((b) =>
                    b.is_alive !== false &&
                    b.player_id !== lobby.last_pass_target_id &&
                    b.player_id !== mePlayerId
                )
                .forEach((bot, idx) => {
                    const key = `${bot.player_id}:${lobby.pass_counter}`;
                    if (warnedRoundsRef.current.has(key)) return;
                    warnedRoundsRef.current.add(key);

                    // 5% Chance — sonst hält der Bot die Klappe
                    if (Math.random() >= 0.05) return;

                    const delay = 1500 + idx * 200 + Math.random() * 1500;
                    window.setTimeout(() => {
                        void supabase.rpc("rpc_warn_player", {
                            p_code: lobby.code,
                            p_warner_player_id: bot.player_id,
                        });
                    }, delay);
                });
        }
    }, [isHost, lobby, players, mePlayerId, supabase]);
}
