"use client";

import React, { useEffect, useState } from "react";

type Piece = {
    id: number;
    leftPct: number;
    delayMs: number;
    durationMs: number;
    rotation: number;
    drift: number;
    color: string;
    size: number;
};

const COLORS = [
    "#ff2d55",
    "#ff9500",
    "#ffd60a",
    "#34c759",
    "#0a84ff",
    "#bf5af2",
    "#ff375f",
    "#5ac8fa",
];

type Props = {
    /** Toggle to true to fire a burst. Each true→false→true cycle re-fires. */
    active: boolean;
    /** Number of pieces in the burst (default 90). */
    pieces?: number;
};

/**
 * Lightweight CSS-only confetti rain. Auto-cleans after the burst ends.
 * Respects prefers-reduced-motion (no-op).
 */
export function Confetti({ active, pieces: count = 90 }: Props) {
    const [pieces, setPieces] = useState<Piece[] | null>(null);

    useEffect(() => {
        if (!active) {
            // defer clearing off the effect body
            const t = window.setTimeout(() => setPieces(null), 0);
            return () => window.clearTimeout(t);
        }
        if (typeof window !== "undefined") {
            const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
            if (reduce) {
                const t = window.setTimeout(() => setPieces(null), 0);
                return () => window.clearTimeout(t);
            }
        }

        const fresh: Piece[] = Array.from({ length: count }, (_, i) => ({
            id: i,
            leftPct: Math.random() * 100,
            delayMs: Math.random() * 250,
            durationMs: 2200 + Math.random() * 1600,
            rotation: Math.random() * 360,
            drift: (Math.random() - 0.5) * 220,
            color: COLORS[Math.floor(Math.random() * COLORS.length)]!,
            size: 6 + Math.round(Math.random() * 10),
        }));
        const showT = window.setTimeout(() => setPieces(fresh), 0);
        const cleanupT = window.setTimeout(() => setPieces(null), 4500);
        return () => {
            window.clearTimeout(showT);
            window.clearTimeout(cleanupT);
        };
    }, [active, count]);

    if (!pieces) return null;

    return (
        <div aria-hidden className="kumpirConfettiHost">
            {pieces.map((p) => (
                <span
                    key={p.id}
                    className="kumpirConfettiPiece"
                    style={{
                        left: `${p.leftPct}%`,
                        width: p.size,
                        height: p.size * 0.4,
                        background: p.color,
                        animationDelay: `${p.delayMs}ms`,
                        animationDuration: `${p.durationMs}ms`,
                        // CSS variables for the keyframes
                        ["--rot" as string]: `${p.rotation}deg`,
                        ["--drift" as string]: `${p.drift}px`,
                    } as React.CSSProperties}
                />
            ))}

            <style jsx global>{`
        .kumpirConfettiHost {
          position: fixed;
          inset: 0;
          pointer-events: none;
          z-index: 9998;
          overflow: hidden;
        }
        .kumpirConfettiPiece {
          position: absolute;
          top: -16px;
          border-radius: 2px;
          opacity: 0.95;
          box-shadow: 0 4px 14px rgba(0, 0, 0, 0.18);
          animation-name: kumpirConfettiFall;
          animation-timing-function: cubic-bezier(0.2, 0.7, 0.2, 1);
          animation-fill-mode: forwards;
          will-change: transform, opacity;
        }
        @keyframes kumpirConfettiFall {
          0% {
            transform: translate3d(0, -10vh, 0) rotate(var(--rot));
            opacity: 0;
          }
          12% {
            opacity: 1;
          }
          100% {
            transform: translate3d(var(--drift), 110vh, 0) rotate(calc(var(--rot) + 720deg));
            opacity: 0;
          }
        }
      `}</style>
        </div>
    );
}
