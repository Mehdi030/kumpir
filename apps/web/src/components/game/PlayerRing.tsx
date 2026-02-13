"use client";

import React, { useLayoutEffect, useMemo, useRef } from "react";

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

export type PlayerPosMap = Record<string, { x: number; y: number }>;

export function PlayerRing({
                               players,
                               holderPlayerId,
                               mePlayerId,
                               onPositions,
                           }: {
    players: Player[];
    holderPlayerId: string | null;
    mePlayerId: string | null;
    onPositions?: (map: PlayerPosMap) => void;
}) {
    const containerRef = useRef<HTMLDivElement | null>(null);

    const ordered = useMemo(() => reorder(players, mePlayerId), [players, mePlayerId]);
    const n = ordered.length;

    // Layout parameters
    const radius = Math.min(320, Math.max(160, 120 + n * 18));
    const ellipseY = 0.62;

    // Compute positions in container coords
    const layout = useMemo(() => {
        return ordered.map((p, idx) => {
            const a = computeAngle(idx, n);
            const x = Math.cos(a) * radius;
            const y = Math.sin(a) * radius * ellipseY;
            return { id: p.player_id, x, y };
        });
    }, [ordered, n, radius]);

    // Report viewport positions for flying potato
    useLayoutEffect(() => {
        if (!onPositions) return;
        const el = containerRef.current;
        if (!el) return;

        const rect = el.getBoundingClientRect();
        const cx = rect.left + rect.width / 2;
        const cy = rect.top + rect.height * 0.62; // same anchor as render (top: 62%)

        const map: PlayerPosMap = {};
        for (const pt of layout) {
            map[pt.id] = { x: cx + pt.x, y: cy + pt.y };
        }
        onPositions(map);
    }, [layout, onPositions]);

    return (
        <div
            ref={containerRef}
            style={{
                position: "relative",
                height: 260,
                width: "min(980px, 100%)",
                margin: "0 auto",
            }}
        >
            {/* Plate */}
            <div
                aria-hidden
                style={{
                    position: "absolute",
                    left: "50%",
                    top: "62%",
                    transform: "translate(-50%, -50%)",
                    width: "min(920px, 98%)",
                    height: 210,
                    borderRadius: 999,
                    background: "rgba(0,0,0,0.10)",
                    border: "1px solid rgba(255,255,255,0.12)",
                    boxShadow: "0 18px 70px rgba(0,0,0,0.18)",
                }}
            />

            {ordered.map((p, idx) => {
                const isHolder = !!holderPlayerId && p.player_id === holderPlayerId;
                const isMe = !!mePlayerId && p.player_id === mePlayerId;

                const size = isHolder ? 96 : 74;

                const pt = layout[idx];
                const x = pt?.x ?? 0;
                const y = pt?.y ?? 0;

                return (
                    <div
                        key={p.player_id}
                        style={{
                            position: "absolute",
                            left: "50%",
                            top: "62%",
                            transform: `translate(calc(-50% + ${x}px), calc(-50% + ${y}px))`,
                            width: size,
                            height: size,
                            borderRadius: 999,
                            display: "grid",
                            placeItems: "center",
                            textAlign: "center",
                            padding: 10,
                            userSelect: "none",
                            opacity: p.is_alive ? 1 : 0.35,
                            filter: p.is_alive ? "none" : "grayscale(1)",

                            background: isHolder
                                ? "linear-gradient(135deg, rgba(255,70,40,0.92), rgba(255,25,60,0.85))"
                                : "rgba(0,0,0,0.16)",
                            border: isHolder
                                ? "1px solid rgba(255,180,120,0.45)"
                                : "1px solid rgba(255,255,255,0.12)",
                            boxShadow: isHolder
                                ? "0 0 0 2px rgba(255,90,40,0.22), 0 20px 60px rgba(255,60,40,0.22), 0 0 40px rgba(255,90,40,0.22)"
                                : "0 14px 40px rgba(0,0,0,0.18)",
                        }}
                    >
                        <div style={{ lineHeight: 1.05 }}>
                            <div style={{ fontSize: 13, fontWeight: 900 }}>
                                {p.name}
                                {isMe ? " (Du)" : ""}
                            </div>
                            {isHolder && (
                                <div style={{ marginTop: 6, fontSize: 12, fontWeight: 950, opacity: 0.95 }}>
                                    🥔 HOLDER
                                </div>
                            )}
                        </div>
                    </div>
                );
            })}
        </div>
    );
}

/**
 * Layout:
 * - idx=0 ist "me" und sitzt unten (90°)
 * - 2–3 Spieler: schöner Halbkreis unten (nicht kompletter Ring)
 * - 4+ Spieler: kompletter Ring (Ellipse)
 */
function computeAngle(idx: number, n: number) {
    // me unten
    const bottom = Math.PI / 2;

    if (n <= 1) return bottom;

    if (n === 2) {
        // me unten, other leicht links oben (gefühlt)
        return idx === 0 ? bottom : bottom - Math.PI * 0.75;
    }

    if (n === 3) {
        // Halbkreis unten: me unten, zwei oben links/rechts
        const angles = [bottom, bottom - Math.PI * 0.70, bottom + Math.PI * 0.70];
        return angles[idx] ?? bottom;
    }

    // 4+ full ring
    const step = (Math.PI * 2) / n;
    return bottom + idx * step;
}

function reorder(players: Player[], meId: string | null) {
    if (!meId) return players;

    const me = players.find((p) => p.player_id === meId);
    const others = players.filter((p) => p.player_id !== meId);

    return me ? [me, ...others] : players;
}