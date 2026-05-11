"use client";

import { useEffect, useState } from "react";

/**
 * Beobachtet die letzten last_pass_target + last_pass_at Werte und gibt
 * ein "currentTarget" zurück solange das 5s-Warning-Window offen ist.
 * Sobald das Fenster abläuft → currentTarget = null.
 */
type Input = {
    lastPassTargetId: string | null;
    lastPassAt: string | null;
    passCounter: number;
    windowMs?: number;
};

export function useRecentPass({ lastPassTargetId, lastPassAt, passCounter, windowMs = 5000 }: Input) {
    const [now, setNow] = useState(() => Date.now());

    useEffect(() => {
        const t = window.setInterval(() => setNow(Date.now()), 250);
        return () => window.clearInterval(t);
    }, []);

    if (!lastPassTargetId || !lastPassAt) {
        return { targetId: null as string | null, passCounter, secondsLeft: 0 };
    }

    const passAtMs = Date.parse(lastPassAt);
    if (Number.isNaN(passAtMs)) return { targetId: null, passCounter, secondsLeft: 0 };

    const elapsed = now - passAtMs;
    if (elapsed > windowMs) {
        return { targetId: null, passCounter, secondsLeft: 0 };
    }

    return {
        targetId: lastPassTargetId,
        passCounter,
        secondsLeft: Math.max(0, Math.ceil((windowMs - elapsed) / 1000)),
    };
}
