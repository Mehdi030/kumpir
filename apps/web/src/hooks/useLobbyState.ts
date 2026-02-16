"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type LobbyRow = {
    id: string;
    code: string;
    host_player_id: string | null;
    phase: string | null;
    locked: boolean | null; // ✅ NEW
};

export type PlayerRow = {
    player_id: string;
    name: string;
    ready: boolean | null;
    joined_at?: string | null;
};

export function useLobbyState(
    code: string,
    opts?: {
        pollMs?: number;
        onPhaseRunning?: () => void;
    }
) {
    const supabase = getSupabaseClient();
    const pollMs = opts?.pollMs ?? 1200;

    const [lobby, setLobby] = useState<LobbyRow | null>(null);
    const [players, setPlayers] = useState<PlayerRow[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        setError("");

        const lobbyRes = await supabase
            .from("lobbies")
            .select("id,code,host_player_id,phase,locked") // ✅ NEW: locked
            .eq("code", code)
            .single();

        if (lobbyRes.error || !lobbyRes.data) {
            setError(lobbyRes.error?.message || "Lobby nicht gefunden.");
            return;
        }

        const lobbyRow = lobbyRes.data as LobbyRow;

        // ✅ wenn Spiel läuft, raus aus Lobby-Page
        if (lobbyRow.phase === "running") {
            opts?.onPhaseRunning?.();
            return;
        }

        setLobby(lobbyRow);

        const playersRes = await supabase
            .from("players")
            .select("player_id,name,ready,joined_at")
            .eq("lobby_id", lobbyRow.id)
            .order("joined_at", {ascending: true});

        if (playersRes.error) {
            setError(playersRes.error.message || "Konnte Spieler nicht laden.");
            return;
        }

        setPlayers((playersRes.data ?? []) as PlayerRow[]);
    }, [code, supabase, opts]);

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

        const t = window.setInterval(() => load(), pollMs);
        return () => {
            alive = false;
            window.clearInterval(t);
        };
    }, [load, pollMs]);

    return {
        lobby,
        players,
        loading,
        error,
        reload: load,
    };
}