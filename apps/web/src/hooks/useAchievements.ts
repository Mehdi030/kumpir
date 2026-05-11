"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import type { Achievement, PlayerAchievement, PlayerLifetimeStats } from "@/lib/achievements";

type UseAchievementsResult = {
    catalog: Achievement[];
    unlocked: PlayerAchievement[];
    stats: PlayerLifetimeStats | null;
    loading: boolean;
    error: string;
    refresh: () => Promise<void>;
};

/**
 * Loads the achievement catalog + the unlocked achievements + lifetime stats
 * for a given user. If `userId` is null (Gast-Modus), returns empty data.
 */
export function useAchievements(userId: string | null | undefined): UseAchievementsResult {
    const supabase = getSupabaseClient();
    const [catalog, setCatalog] = useState<Achievement[]>([]);
    const [unlocked, setUnlocked] = useState<PlayerAchievement[]>([]);
    const [stats, setStats] = useState<PlayerLifetimeStats | null>(null);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        setError("");
        setLoading(true);

        try {
            // Catalog ist user-unabhängig — kann immer geladen werden
            const catRes = await supabase
                .from("achievements")
                .select("code,title,description,icon,tier")
                .order("tier", { ascending: true });

            if (catRes.error) {
                setError(catRes.error.message);
                return;
            }
            setCatalog((catRes.data ?? []) as unknown as Achievement[]);

            if (!userId) {
                setUnlocked([]);
                setStats(null);
                return;
            }

            const [unlockedRes, statsRes] = await Promise.all([
                supabase
                    .from("player_achievements")
                    .select("user_id,achievement_code,unlocked_at,lobby_id")
                    .eq("user_id", userId)
                    .order("unlocked_at", { ascending: false }),
                supabase
                    .from("player_lifetime_stats")
                    .select("*")
                    .eq("user_id", userId)
                    .maybeSingle(),
            ]);

            if (unlockedRes.error) {
                setError(unlockedRes.error.message);
                return;
            }
            setUnlocked((unlockedRes.data ?? []) as unknown as PlayerAchievement[]);

            if (statsRes.error) {
                setError(statsRes.error.message);
                return;
            }
            setStats((statsRes.data as unknown as PlayerLifetimeStats) ?? null);
        } finally {
            setLoading(false);
        }
    }, [supabase, userId]);

    useEffect(() => {
        void load();
    }, [load]);

    return { catalog, unlocked, stats, loading, error, refresh: load };
}
