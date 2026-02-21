"use client";

import { useEffect, useMemo, useState } from "react";

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

type Props = {
    players: Player[];
    holderPlayerId: string | null;
    mePlayerId: string | null;
};

function clamp(n: number, min: number, max: number) {
    return Math.max(min, Math.min(max, n));
}

export function PlayerRing({ players, holderPlayerId, mePlayerId }: Props) {
    const [vw, setVw] = useState<number>(typeof window !== "undefined" ? window.innerWidth : 1200);
    const [vh, setVh] = useState<number>(typeof window !== "undefined" ? window.innerHeight : 800);

    useEffect(() => {
        const onResize = () => {
            setVw(window.innerWidth);
            setVh(window.innerHeight);
        };
        window.addEventListener("resize", onResize);
        return () => window.removeEventListener("resize", onResize);
    }, []);

    const alivePlayers = useMemo(() => players.filter((p) => p.is_alive), [players]);

    const N = alivePlayers.length || 1;

    const cx = vw / 2;
    const cy = vh / 2;

    // Ellipse radii: keep margin for UI buttons etc.
    const margin = 80;
    const rx = clamp(vw / 2 - margin, 220, 520);
    const ry = clamp(vh / 2 - margin, 160, 420);

    // Keep ring behind primary interaction, but visible
    return (
        <div
            aria-hidden
            style={{
                position: "absolute",
                inset: 0,
                zIndex: 2,
                pointerEvents: "none",
            }}
        >
            {alivePlayers.map((p, i) => {
                const isHolder = !!holderPlayerId && p.player_id === holderPlayerId;
                const isMe = !!mePlayerId && p.player_id === mePlayerId;

                // Start at top (-90deg) and go clockwise
                const angle = (Math.PI * 2 * i) / N - Math.PI / 2;

                const x = cx + Math.cos(angle) * rx;
                const y = cy + Math.sin(angle) * ry;

                const scale = isHolder ? 1.18 : isMe ? 1.08 : 1.0;

                const bg = isHolder
                    ? "rgba(255,90,90,0.22)"
                    : "rgba(0,0,0,0.30)";

                const border = isHolder
                    ? "1px solid rgba(255,160,160,0.40)"
                    : "1px solid rgba(255,255,255,0.10)";

                const glow = isHolder
                    ? "0 0 22px rgba(255,90,90,0.35)"
                    : isMe
                        ? "0 0 18px rgba(255,255,255,0.18)"
                        : "none";

                return (
                    <div
                        key={p.player_id}
                        style={{
                            position: "absolute",
                            left: x,
                            top: y,
                            transform: `translate(-50%, -50%) scale(${scale})`,
                            padding: "10px 14px",
                            borderRadius: 999,
                            background: bg,
                            border,
                            boxShadow: glow,
                            backdropFilter: "blur(10px)",
                            WebkitBackdropFilter: "blur(10px)",
                            fontWeight: 950,
                            letterSpacing: 0.2,
                            whiteSpace: "nowrap",
                            opacity: p.is_alive ? 1 : 0.5,
                        }}
                    >
            <span style={{ marginRight: 8, opacity: 0.85 }}>
              {isHolder ? "🥔" : isMe ? "👤" : "•"}
            </span>
                        <span style={{ opacity: 0.95 }}>{p.name}</span>
                        {isHolder ? <span style={{ marginLeft: 8, opacity: 0.85 }}>HOLDER</span> : null}
                        {!p.is_alive ? <span style={{ marginLeft: 8, opacity: 0.75 }}>💀</span> : null}
                    </div>
                );
            })}
        </div>
    );
}