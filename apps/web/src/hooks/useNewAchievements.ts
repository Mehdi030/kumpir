"use client";

import { useEffect, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { notify } from "@/lib/notifications";
import type { Achievement } from "@/lib/achievements";

type NewAchievement = Achievement & { unlocked_at: string };

/**
 * Beobachtet, wann ein User neue Achievements freischaltet.
 * Triggert auf phaseTransition (z.B. wenn das Spiel zu "finished" wechselt),
 * lädt dann player_achievements + achievements und vergleicht mit dem zuvor
 * gemerkten Stand. Neue Einträge landen in `newOnes`.
 *
 * UI ruft `dismiss(code)` auf, sobald ein Toast geschlossen wurde.
 */
export function useNewAchievements(userId: string | null | undefined, triggerKey: unknown) {
    const supabase = getSupabaseClient();
    const knownCodesRef = useRef<Set<string> | null>(null);
    const [newOnes, setNewOnes] = useState<NewAchievement[]>([]);

    // Initial bekannten Stand laden (ohne newOnes auszulösen)
    useEffect(() => {
        if (!userId) {
            knownCodesRef.current = new Set();
            return;
        }

        let alive = true;
        void (async () => {
            const res = await supabase
                .from("player_achievements")
                .select("achievement_code")
                .eq("user_id", userId);
            if (!alive) return;
            const codes = (res.data ?? []).map((r: { achievement_code: string }) => r.achievement_code);
            knownCodesRef.current = new Set(codes);
        })();

        return () => { alive = false; };
    }, [supabase, userId]);

    // Bei triggerKey-Änderung: prüfe ob neue Achievements da sind
    useEffect(() => {
        if (!userId) return;
        if (knownCodesRef.current == null) return;

        let alive = true;
        // Kleiner Delay damit Trigger in der DB Zeit hat
        const t = window.setTimeout(async () => {
            const [unlockedRes, catRes] = await Promise.all([
                supabase
                    .from("player_achievements")
                    .select("achievement_code,unlocked_at")
                    .eq("user_id", userId),
                supabase
                    .from("achievements")
                    .select("code,title,description,icon,tier"),
            ]);
            if (!alive) return;
            if (unlockedRes.error || catRes.error) return;

            const known = knownCodesRef.current ?? new Set<string>();
            const allUnlocked = (unlockedRes.data ?? []) as Array<{ achievement_code: string; unlocked_at: string }>;
            const fresh = allUnlocked.filter((u) => !known.has(u.achievement_code));
            if (fresh.length === 0) return;

            const catalog = (catRes.data ?? []) as Achievement[];
            const enriched: NewAchievement[] = fresh
                .map((u) => {
                    const ach = catalog.find((a) => a.code === u.achievement_code);
                    if (!ach) return null;
                    return { ...ach, unlocked_at: u.unlocked_at };
                })
                .filter((v): v is NewAchievement => v !== null);

            // Mark them als known (damit Re-Trigger nichts nochmal zeigt)
            for (const u of allUnlocked) known.add(u.achievement_code);
            knownCodesRef.current = known;

            setNewOnes((prev) => [...prev, ...enriched]);

            // Browser-Notifications (eine pro Achievement, nur wenn Tab im Hintergrund)
            for (const a of enriched) {
                notify(`${a.icon} ${a.title}`, a.description, { tag: `achievement:${a.code}` });
            }
        }, 1200);

        return () => {
            alive = false;
            window.clearTimeout(t);
        };
    }, [supabase, userId, triggerKey]);

    const dismiss = (code: string) => {
        setNewOnes((prev) => prev.filter((a) => a.code !== code));
    };

    return { newOnes, dismiss };
}
