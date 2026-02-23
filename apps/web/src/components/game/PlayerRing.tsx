"use client";

import { useEffect, useMemo, useRef, useState } from "react";

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

export type PassEvent = {
    fromPlayerId: string;
    toPlayerId: string;
    nonce: number;
};

type Props = {
    players: Player[];
    holderPlayerId: string | null;
    mePlayerId: string | null;
    passEvent?: PassEvent | null;
};

function clamp(n: number, min: number, max: number) {
    return Math.max(min, Math.min(max, n));
}

function getReduceMotion(): boolean {
    if (typeof window === "undefined") return false;
    const mq = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    return !!mq?.matches;
}

export function PlayerRing({ players, holderPlayerId, mePlayerId, passEvent }: Props) {
    const [vw, setVw] = useState<number>(typeof window !== "undefined" ? window.innerWidth : 1200);
    const [vh, setVh] = useState<number>(typeof window !== "undefined" ? window.innerHeight : 800);

    const [reduceMotion, setReduceMotion] = useState(false);

    // flying potato state
    const [fly, setFly] = useState<null | {
        x: number;
        y: number;
        tx: number;
        ty: number;
        active: boolean;
        nonce: number;
    }>(null);

    const flyTimeoutRef = useRef<number | null>(null);

    useEffect(() => {
        setReduceMotion(getReduceMotion());
        const mq = window.matchMedia?.("(prefers-reduced-motion: reduce)");
        const onChange = () => setReduceMotion(getReduceMotion());
        mq?.addEventListener?.("change", onChange);
        return () => mq?.removeEventListener?.("change", onChange);
    }, []);

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

    const margin = 80;
    const rx = clamp(vw / 2 - margin, 220, 520);
    const ry = clamp(vh / 2 - margin, 160, 420);

    // precompute positions for current alivePlayers ordering
    const pos = useMemo(() => {
        const m = new Map<string, { x: number; y: number }>();
        for (let i = 0; i < alivePlayers.length; i++) {
            const p = alivePlayers[i];
            const angle = (Math.PI * 2 * i) / N - Math.PI / 2;
            const x = cx + Math.cos(angle) * rx;
            const y = cy + Math.sin(angle) * ry;
            m.set(p.player_id, { x, y });
        }
        return m;
    }, [alivePlayers, N, cx, cy, rx, ry]);

    // run flying potato animation on passEvent
    useEffect(() => {
        if (!passEvent) return;

        const from = pos.get(passEvent.fromPlayerId);
        const to = pos.get(passEvent.toPlayerId);
        if (!from || !to) return;

        // cancel previous
        if (flyTimeoutRef.current) window.clearTimeout(flyTimeoutRef.current);

        if (reduceMotion) {
            // reduced motion: just "pop" at target briefly
            setFly({ x: to.x, y: to.y, tx: to.x, ty: to.y, active: true, nonce: passEvent.nonce });
            flyTimeoutRef.current = window.setTimeout(() => setFly(null), 500);
            return;
        }

        // start at from, then animate to to
        setFly({ x: from.x, y: from.y, tx: to.x, ty: to.y, active: false, nonce: passEvent.nonce });

        const raf = window.requestAnimationFrame(() => {
            setFly((prev) => (prev ? { ...prev, active: true } : prev));
        });

        flyTimeoutRef.current = window.setTimeout(() => {
            setFly(null);
            window.cancelAnimationFrame(raf);
        }, 650);

        return () => {
            window.cancelAnimationFrame(raf);
        };
    }, [passEvent, pos, reduceMotion]);

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
            {/* flying potato layer */}
            {fly ? (
                <div
                    style={{
                        position: "absolute",
                        left: fly.active ? fly.tx : fly.x,
                        top: fly.active ? fly.ty : fly.y,
                        transform: "translate(-50%, -50%)",
                        transition: reduceMotion ? "none" : "left 520ms cubic-bezier(.2,1,.2,1), top 520ms cubic-bezier(.2,1,.2,1), transform 520ms cubic-bezier(.2,1,.2,1)",
                        filter: "drop-shadow(0 12px 22px rgba(0,0,0,0.35))",
                        fontSize: 30,
                        fontWeight: 900,
                        opacity: 0.95,
                        zIndex: 5,
                    }}
                >
                    🥔
                </div>
            ) : null}

            {alivePlayers.map((p) => {
                const isHolder = !!holderPlayerId && p.player_id === holderPlayerId;
                const isMe = !!mePlayerId && p.player_id === mePlayerId;

                const xy = pos.get(p.player_id);
                if (!xy) return null;

                const scale = isHolder ? 1.18 : isMe ? 1.08 : 1.0;

                const bg = isHolder ? "rgba(255,90,90,0.22)" : "rgba(0,0,0,0.30)";

                const border = isHolder ? "1px solid rgba(255,160,160,0.40)" : "1px solid rgba(255,255,255,0.10)";

                const glow = isHolder ? "0 0 22px rgba(255,90,90,0.35)" : isMe ? "0 0 18px rgba(255,255,255,0.18)" : "none";

                return (
                    <div
                        key={p.player_id}
                        style={{
                            position: "absolute",
                            left: xy.x,
                            top: xy.y,
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
                            opacity: 1,
                        }}
                    >
                        <span style={{ marginRight: 8, opacity: 0.85 }}>{isHolder ? "🥔" : isMe ? "👤" : "•"}</span>
                        <span style={{ opacity: 0.95 }}>{p.name}</span>
                        {/* kein extra “HOLDER” Text mehr -> weniger doppelt/visuell cleaner */}
                    </div>
                );
            })}
        </div>
    );
}