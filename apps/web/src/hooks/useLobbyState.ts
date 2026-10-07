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
    series_total: number | null;
    answer_mode: string | null;
    topic_filter: string[] | null;
};

export type PlayerRow = {
    player_id: string;
    name: string;
    ready: boolean | null;
    joined_at?: string | null;
    status?: "active" | "left" | "kicked" | string;
    is_bot?: boolean | null;
    bot_skill?: number | null;
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

    // Gibt es die Lobby nicht (mehr), wird nicht weiter abgefragt -- vorher fragte ein offener Tab
    // mit "Lobby nicht gefunden" ~1,5x pro Sekunde endlos beim Server nach.
    const goneRef = useRef(false);

    const load = useCallback(async () => {
        if (goneRef.current) return;
        setError("");

        const lobbyRes = await supabase
            .from("lobbies")
            .select("id,code,host_player_id,phase,locked,max_players,game_mode,topic,series_total,answer_mode,topic_filter")
            .eq("code", code)
            .single();

        if (lobbyRes.error?.code === "PGRST116") goneRef.current = true; // 0 Zeilen = Lobby existiert nicht
        if (lobbyRes.error || !lobbyRes.data) {
            // Transient fetch error: keep last known-good lobby/players so callers
            // (e.g. the "removed from lobby" detection) don't misread a network
            // blip as the player having left/been kicked.
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
            .select("player_id,name,ready,joined_at,status,is_bot,bot_skill")
            .eq("lobby_id", lobbyRow.id)
            .eq("status", "active")
            .order("joined_at", { ascending: true });

        if (playersRes.error) {
            // Keep the last known-good players list on a transient error (see above).
            setError(playersRes.error.message || "Konnte Spieler nicht laden.");
            return;
        }

        setPlayers((playersRes.data ?? []) as PlayerRow[]);
    }, [code, supabase]);

    // Realtime-first: when the channel is "live", we react to events. Polling
    // continues as a safety net but at a slower cadence.
    // `load` is passed directly (not wrapped in a fresh arrow fn) because it's
    // already stable via useCallback — a new callback identity here would make
    // useLobbyRealtime's effect re-subscribe the channel on every render.
    const realtimeStatus: RealtimeStatus = useLobbyRealtime(lobby?.id ?? null, load);

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
