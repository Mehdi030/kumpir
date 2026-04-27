"use client";

import { useEffect } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

/**
 * Subscribes to Supabase Realtime changes on lobbies + players for the given lobby
 * and triggers `onChange()` on every event. Polling stays in place as a fallback,
 * so this is purely additive — failures are silent.
 */
export function useLobbyRealtime(lobbyId: string | null | undefined, onChange: () => void) {
    useEffect(() => {
        if (!lobbyId) return;
        const supabase = getSupabaseClient();

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
            .subscribe();

        return () => {
            void supabase.removeChannel(channel);
        };
    }, [lobbyId, onChange]);
}
