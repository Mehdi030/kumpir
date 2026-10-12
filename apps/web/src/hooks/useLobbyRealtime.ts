"use client";

import { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type RealtimeStatus = "idle" | "connecting" | "live" | "reconnecting" | "offline";

/**
 * Subscribes to Supabase Realtime changes on lobbies + players for the given lobby
 * and triggers `onChange()` on every event. Polling stays in place as a fallback,
 * so this is purely additive — failures are silent.
 *
 * Returns the current channel status so the UI can show a connection indicator.
 */
export function useLobbyRealtime(lobbyId: string | null | undefined, onChange: () => void): RealtimeStatus {
    const [status, setStatus] = useState<RealtimeStatus>("idle");

    useEffect(() => {
        if (!lobbyId) {
            const t = window.setTimeout(() => setStatus("idle"), 0);
            return () => window.clearTimeout(t);
        }
        const supabase = getSupabaseClient();
        const initT = window.setTimeout(() => setStatus("connecting"), 0);

        const channel = supabase
            .channel(`lobby:${lobbyId}`)
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "lobbies", filter: `id=eq.${lobbyId}` },
                () => onChange()
            )
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "players", filter: `lobby_id=eq.${lobbyId}` },
                () => onChange()
            )
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "topic_votes", filter: `lobby_id=eq.${lobbyId}` },
                () => onChange()
            )
            .subscribe((event: string) => {
                // Supabase Realtime status callback. Possible values include
                // "SUBSCRIBED", "CHANNEL_ERROR", "TIMED_OUT", "CLOSED".
                if (event === "SUBSCRIBED") setStatus("live");
                else if (event === "CHANNEL_ERROR" || event === "TIMED_OUT") setStatus("reconnecting");
                else if (event === "CLOSED") setStatus("offline");
            });

        // Schneller Weg (Migration 097): die Datenbank schickt jede Lobby-/Spieleränderung als Broadcast.
        // Kommt im Mittel nach ~60 ms an statt ~440 ms (postgres_changes prüft Rechte pro Zuhörer).
        // postgres_changes oben bleibt als Rückfallebene bestehen; doppelte Signale fasst die Spielseite zusammen.
        const fast = supabase
            .channel(`kumpir:${lobbyId}`)
            .on("broadcast", { event: "lobby" }, () => onChange())
            .on("broadcast", { event: "players" }, () => onChange())
            .subscribe();

        return () => {
            window.clearTimeout(initT);
            setStatus("idle");
            void supabase.removeChannel(channel);
            void supabase.removeChannel(fast);
        };
    }, [lobbyId, onChange]);

    return status;
}
