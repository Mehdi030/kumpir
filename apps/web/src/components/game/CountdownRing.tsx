"use client";

import type { CSSProperties } from "react";

/** Große Countdown-Zahl in einem Ring, der pro Sekunde weiter abläuft (Countdown vor dem Start, Revanche). */
export function CountdownRing({ seconds, total, size = 190 }: { seconds: number; total: number; size?: number }) {
    const r = 52;
    const c = 2 * Math.PI * r;
    const frac = total > 0 ? Math.max(0, Math.min(1, seconds / total)) : 0;
    return (
        <div className="cdRing" style={{ width: size, height: size, ["--cd-size" as string]: `${size}px` } as CSSProperties} role="timer" aria-label={`Noch ${seconds} Sekunden`}>
            <svg viewBox="0 0 120 120" aria-hidden>
                <defs>
                    <linearGradient id="cdRingGrad" x1="0" y1="0" x2="1" y2="1">
                        <stop offset="0" stopColor="#ffe27a" />
                        <stop offset=".55" stopColor="#ff9f1c" />
                        <stop offset="1" stopColor="#ff3d2e" />
                    </linearGradient>
                </defs>
                <circle className="cdTrack" cx="60" cy="60" r={r} />
                <circle className="cdProg" cx="60" cy="60" r={r} strokeDasharray={c} strokeDashoffset={c * (1 - frac)} />
            </svg>
            <span key={seconds} className="cdRingNum">
                {seconds}
            </span>
        </div>
    );
}
