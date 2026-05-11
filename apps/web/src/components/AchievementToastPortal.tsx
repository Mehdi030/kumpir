"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import type { Achievement } from "@/lib/achievements";
import { AchievementToast } from "./AchievementToast";

type Props = {
    achievements: Array<Achievement & { unlocked_at: string }>;
    onDismiss: (code: string) => void;
};

/**
 * Rendert Achievement-Toasts in einem Portal an document.body, damit sie über
 * den ganzen Bildschirm sichtbar sind, unabhängig von der aktuellen Game-Phase.
 */
export function AchievementToastPortal({ achievements, onDismiss }: Props) {
    const [mounted, setMounted] = useState(false);
    useEffect(() => {
        // eslint-disable-next-line react-hooks/set-state-in-effect
        setMounted(true);
    }, []);

    if (!mounted || typeof document === "undefined" || achievements.length === 0) return null;

    return createPortal(
        <div
            style={{
                position: "fixed",
                top: 20,
                right: 20,
                zIndex: 10_000,
                display: "flex",
                flexDirection: "column",
                gap: 10,
                pointerEvents: "none",
            }}
            aria-live="polite"
        >
            {achievements.map((a) => (
                <div key={a.code} style={{ pointerEvents: "auto" }}>
                    <AchievementToast achievement={a} onDismiss={() => onDismiss(a.code)} />
                </div>
            ))}
        </div>,
        document.body
    );
}
