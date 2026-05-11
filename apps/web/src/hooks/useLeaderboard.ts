"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type LeaderboardEntry = {
    user_id: string;
    username: string;
    games_played: number;
    wins: number;
    win_rate_pct: number;
    total_passes: number;
    total_clutch_passes: number;
    fastest_pass_ms: number | null;
    total_hold_ms: number;
    best_survival_streak: number;
};

export type LeaderboardCategory = "wins" | "passes" | "clutch" | "fastest" | "streak";

const SORT_FOR_CATEGORY: Record<LeaderboardCategory, { col: keyof LeaderboardEntry; asc: boolean }> = {
    wins:    { col: "wins",                 asc: false },
    passes:  { col: "total_passes",         asc: false },
    clutch:  { col: "total_clutch_passes",  asc: false },
    fastest: { col: "fastest_pass_ms",      asc: true  }, // niedriger = besser
    streak:  { col: "best_survival_streak", asc: false },
};

export function useLeaderboard(category: LeaderboardCategory, limit: number = 25) {
    const supabase = getSupabaseClient();
    const [rows, setRows] = useState<LeaderboardEntry[]>([]);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        setError("");
        setLoading(true);

        const sort = SORT_FOR_CATEGORY[category];
        try {
            const res = await supabase
                .from("leaderboard_view")
                .select("*")
                .order(String(sort.col), { ascending: sort.asc, nullsFirst: false })
                .limit(limit);

            if (res.error) {
                setError(res.error.message);
                setRows([]);
                return;
            }
            setRows((res.data ?? []) as unknown as LeaderboardEntry[]);
        } finally {
            setLoading(false);
        }
    }, [supabase, category, limit]);

    useEffect(() => {
        void load();
    }, [load]);

    return { rows, loading, error, refresh: load };
}
