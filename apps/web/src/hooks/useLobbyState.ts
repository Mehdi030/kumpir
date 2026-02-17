"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type LobbyRow = {
    id: string;
    code: string;
    host_player_id: string | null;
    phase: string | null;
    locked: boolean | null;

    max_players: number | null;
    mode: string | null;
    topic: string | null;
};

export type PlayerRow = {
    player_id: string;
    name: string;
    ready: boolean | null;
    joined_at?: string | null;
    status?: "active" | "left" | "kicked" | string;
};

type UseLobbyStateOpts = {
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

    const [lobby, setLobby] = useState<LobbyRow | null>(null);
    const [players, setPlayers] = useState<PlayerRow[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        setError("");

        const lobbyRes = await supabase
            .from("lobbies")
            .select("id,code,host_player_id,phase,locked,max_players,mode,topic")
            .eq("code", code)
            .single();

        if (lobbyRes.error || !lobbyRes.data) {
            setLobby(null);
            setPlayers([]);
            setError(lobbyRes.error?.message || "Lobby nicht gefunden.");
            return;
        }

        const lobbyRow = lobbyRes.data as LobbyRow;

        if (lobbyRow.phase === "running") {
            onPhaseRunningRef.current?.();
            return;
        }

        setLobby(lobbyRow);

        const playersRes = await supabase
            .from("players")
            .select("player_id,name,ready,joined_at,status")
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

        const t = window.setInterval(() => void load(), pollMs);
        return () => {
            alive = false;
            window.clearInterval(t);
        };
    }, [load, pollMs]);

    return { lobby, players, loading, error, reload: load };
}