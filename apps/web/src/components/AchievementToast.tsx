"use client";

import { useEffect, useState } from "react";
import type { Achievement } from "@/lib/achievements";
import { TIER_STYLE } from "@/lib/achievements";

type Props = {
    achievement: Achievement;
    onDismiss: () => void;
    autoDismissMs?: number;
};

/**
 * Vollbreite "Du hast XYZ freigeschaltet!"-Karte. Wird vom AchievementToastStack
 * gerendert wenn neue Achievements unlocked werden.
 */
export function AchievementToast({ achievement, onDismiss, autoDismissMs = 5000 }: Props) {
    const style = TIER_STYLE[achievement.tier] ?? TIER_STYLE.bronze;
    const [enter, setEnter] = useState(false);

    useEffect(() => {
        const t1 = window.setTimeout(() => setEnter(true), 30);
        const t2 = window.setTimeout(() => onDismiss(), autoDismissMs);
        return () => {
            window.clearTimeout(t1);
            window.clearTimeout(t2);
        };
    }, [autoDismissMs, onDismiss]);

    return (
        <button
            type="button"
            onClick={onDismiss}
            style={{
                position: "relative",
                display: "flex",
                alignItems: "center",
                gap: 14,
                padding: "14px 18px",
                borderRadius: 16,
                border: `2px solid ${style.border}`,
                background: style.bg,
                boxShadow: style.glow,
                color: "white",
                width: "min(420px, 92vw)",
                opacity: enter ? 1 : 0,
                transform: enter ? "translateX(0)" : "translateX(40px)",
                transition: "opacity .35s ease, transform .35s cubic-bezier(.2,1,.2,1)",
                cursor: "pointer",
                textAlign: "left",
            }}
            aria-label={`Achievement freigeschaltet: ${achievement.title}`}
        >
            <div style={{ fontSize: 38, lineHeight: 1 }}>{achievement.icon}</div>
            <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 11, fontWeight: 950, letterSpacing: 1.2, textTransform: "uppercase", opacity: 0.85 }}>
                    🎉 Freigeschaltet
                </div>
                <div style={{ fontSize: 17, fontWeight: 900, marginTop: 2 }}>{achievement.title}</div>
                <div style={{ fontSize: 12, fontWeight: 700, opacity: 0.88, marginTop: 2 }}>{achievement.description}</div>
            </div>
        </button>
    );
}
