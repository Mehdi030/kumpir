"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useLobbyRealtime, type RealtimeStatus } from "@/hooks/useLobbyRealtime";

export type LobbyRow = {
    id: string;
    code: string;
    host_player_id: string | null;
    phase: string | null;
    locked: boolean | null;
    max_players: number | null;
    game_mode: string | null;
    topic: string | null;
};

export type PlayerRow = {
    player_id: string;
    name: string;
    ready: boolean | null;
    joined_at?: string | null;
    status?: "active" | "left" | "kicked" | string;
    is_bot?: boolean | null;
};

type UseLobbyStateOpts = {
    /**
     * Polling cadence (ms) when Realtime is NOT connected (fallback).
     * When the Realtime channel reports "live", polling is paused.
     * Default: 1200ms (only takes effect on offline/connecting).
     */
    pollMs?: number;
    onPhaseRunning?: () => void;
};

export function useLobbyState(code: string, opts?: UseLobbyStateOpts) {
    const supabase = getSupabaseClient();
    const pollMs = opts?.pollMs ?? 1200;

    const onPhaseRunningRef = useRef<(() => void) | undefined>(opts?.onPhaseRunning);
    useEffect(() => {
        onPhaseRunningRef.current = opts?.onPhaseRunning;
    }, [opts?.onPhaseRunning]);

    const prevPhaseRef = useRef<string | null>(null);

    const [lobby, setLobby] = useState<LobbyRow | null>(null);
    const [players, setPlayers] = useState<PlayerRow[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        setError("");

        const lobbyRes = await supabase
            .from("lobbies")
            .select("id,code,host_player_id,phase,locked,max_players,game_mode,topic")
            .eq("code", code)
            .single();

        if (lobbyRes.error || !lobbyRes.data) {
            setLobby(null);
            setPlayers([]);
            setError(lobbyRes.error?.message || "Lobby nicht gefunden.");
            return;
        }

        const lobbyRow = lobbyRes.data as LobbyRow;
        setLobby(lobbyRow);

        const prev = prevPhaseRef.current;
        const next = lobbyRow.phase ?? null;
        if (prev !== "running" && next === "running") {
            onPhaseRunningRef.current?.();
        }
        prevPhaseRef.current = next;

        const playersRes = await supabase
            .from("players")
            .select("player_id,name,ready,joined_at,status,is_bot")
            .eq("lobby_id", lobbyRow.id)
            .eq("status", "active")
            .order("joined_at", { ascending: true });

        if (playersRes.error) {
            setPlayers([]);
            setError(playersRes.error.message || "Konnte Spieler nicht laden.");
            return;
        }

        setPlayers((playersRes.data ?? []) as PlayerRow[]);
    }, [code, supabase]);

    // Realtime-first: when the channel is "live", we react to events. Polling
    // continues as a safety net but at a slower cadence.
    const realtimeStatus: RealtimeStatus = useLobbyRealtime(lobby?.id ?? null, () => {
        void load();
    });

    useEffect(() => {
        let alive = true;

        (async () => {
            setLoading(true);
            try {
                await load();
            } finally {
                if (alive) setLoading(false);
            }
        })();

        // Effective poll interval: tight when realtime is offline/connecting,
        // relaxed (much slower) when realtime is live.
        const effectiveMs = realtimeStatus === "live" ? Math.max(pollMs * 8, 6000) : pollMs;

        const t = window.setInterval(() => void load(), effectiveMs);
        return () => {
            alive = false;
            window.clearInterval(t);
        };
    }, [load, pollMs, realtimeStatus]);

    return { lobby, players, loading, error, reload: load, realtimeStatus };
}
