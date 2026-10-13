"use client";

import { useCallback, useEffect, useState } from "react";
import type { Achievement } from "@/lib/achievements";
import { AchievementToast } from "@/components/AchievementToast";
import { takeAchievementRecap } from "@/components/AchievementBurst";

/**
 * Nach der Runde: in der Lobby bzw. im Hauptmenü stehen die frisch freigeschalteten Erfolge noch einmal kurz
 * unten rechts (Wunsch Mehdi 2026-10-13). Liest die Liste, die die Spielseite gemerkt hat, und leert sie.
 */
export function AchievementRecap() {
    const [list, setList] = useState<Achievement[]>([]);
    useEffect(() => {
        const t = window.setTimeout(() => setList(takeAchievementRecap() as Achievement[]), 600);
        return () => window.clearTimeout(t);
    }, []);
    const dismiss = useCallback((code: string) => setList((l) => l.filter((a) => a.code !== code)), []);
    if (!list.length) return null;
    return (
        <div className="achRecap" aria-live="polite">
            {list.map((a) => (
                <AchievementToast key={a.code} achievement={a} onDismiss={() => dismiss(a.code)} autoDismissMs={6500} />
            ))}
            <style>{`
        .achRecap{ position: fixed; right: 16px; bottom: 16px; z-index: 9000; display: grid; gap: 10px; justify-items: end; }
        @media (max-width: 520px){ .achRecap{ right: 8px; left: 8px; bottom: 8px; justify-items: stretch; } }
      `}</style>
        </div>
    );
}
