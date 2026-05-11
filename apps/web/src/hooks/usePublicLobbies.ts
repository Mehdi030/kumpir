"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type PublicLobby = {
    code: string;
    max_players: number;
    game_mode: string;
    round_speed: string;
    player_count: number;
    created_at: string;
};

/**
 * Lädt offene öffentliche Lobbies aus der public_lobbies_view.
 * Refresht alle `refreshMs` (default 5s) damit das Hauptmenü aktuell bleibt.
 */
export function usePublicLobbies(refreshMs: number = 5000) {
    const supabase = getSupabaseClient();
    const [rows, setRows] = useState<PublicLobby[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        setError("");
        try {
            const res = await supabase
                .from("public_lobbies_view")
                .select("code,max_players,game_mode,round_speed,player_count,created_at")
                .limit(10);

            if (res.error) {
                // View existiert evtl. noch nicht — silent fail, kein User-Alarm
                setError(res.error.message);
                return;
            }
            setRows((res.data ?? []) as PublicLobby[]);
        } finally {
            setLoading(false);
        }
    }, [supabase]);

    useEffect(() => {
        void load();
        const t = window.setInterval(() => void load(), refreshMs);
        return () => window.clearInterval(t);
    }, [load, refreshMs]);

    return { rows, loading, error, refresh: load };
}
