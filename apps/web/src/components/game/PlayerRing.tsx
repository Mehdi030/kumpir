"use client";

import React, { useEffect, useMemo, useRef, useState } from "react";

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
    ready?: boolean;
    // optional seat_index wenn du es hier drin hast
    // seat_index?: number;
};

type PassEvent = {
    fromPlayerId: string;
    toPlayerId: string;
    nonce: number;
};

type Props = {
    players: Player[];
    holderPlayerId: string | null;
    mePlayerId: string | null;
    passEvent: PassEvent | null;
};

type Pt = { x: number; y: number };

function easeInOutCubic(t: number) {
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

// Quadratic Bezier
function bezier(p0: Pt, p1: Pt, p2: Pt, t: number): Pt {
    const u = 1 - t;
    return {
        x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
        y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y,
    };
}

export function PlayerRing({ players, holderPlayerId, mePlayerId, passEvent }: Props) {
    const containerRef = useRef<HTMLDivElement | null>(null);

    // Flying potato state
    const [fly, setFly] = useState<{
        nonce: number;
        fromId: string;
        toId: string;
        t: number; // 0..1
    } | null>(null);

    // Receiver pop highlight
    const [popPlayerId, setPopPlayerId] = useState<string | null>(null);

    // Reduced motion
    const [reduceMotion, setReduceMotion] = useState(false);
    useEffect(() => {
        const mq = window.matchMedia?.("(prefers-reduced-motion: reduce)");
        const apply = () => setReduceMotion(!!mq?.matches);
        apply();
        mq?.addEventListener?.("change", apply);
        return () => mq?.removeEventListener?.("change", apply);
    }, []);

    // Compute positions on ring (in container coords)
    const positions = useMemo(() => {
        const n = players.length;
        const map = new Map<string, Pt>();
        // fallback if no layout
        if (n === 0) return map;

        // We'll assume the ring container is square-ish; we compute relative coords,
        // then convert to px using container size.
        // Use a slightly top-biased start angle so "top" seat feels natural.
        const startAngle = -Math.PI / 2;
        const step = (Math.PI * 2) / n;

        // Base radius in % (converted later)
        for (let i = 0; i < n; i++) {
            const a = startAngle + i * step;
            // relative [-1..1]
            const x = Math.cos(a);
            const y = Math.sin(a);
            map.set(players[i]!.player_id, { x, y });
        }
        return map;
    }, [players]);

    // Convert relative coords to px coords at runtime
    const getPx = (id: string): Pt | null => {
        const rel = positions.get(id);
        const el = containerRef.current;
        if (!rel || !el) return null;

        const rect = el.getBoundingClientRect();
        const size = Math.min(rect.width, rect.height);

        const cx = rect.width / 2;
        const cy = rect.height / 2;

        // radius: leave padding for avatars
        const r = size * 0.38;

        return {
            x: cx + rel.x * r,
            y: cy + rel.y * r,
        };
    };

    // Trigger nicer animation on passEvent
    useEffect(() => {
        if (!passEvent) return;
        if (reduceMotion) {
            // still pop receiver briefly
            setPopPlayerId(passEvent.toPlayerId);
            const t = window.setTimeout(() => setPopPlayerId(null), 380);
            return () => window.clearTimeout(t);
        }

        // start fly
        setFly({
            nonce: passEvent.nonce,
            fromId: passEvent.fromPlayerId,
            toId: passEvent.toPlayerId,
            t: 0,
        });
    }, [passEvent, reduceMotion]);

    // Animate fly.t with rAF
    useEffect(() => {
        if (!fly) return;

        let raf = 0;
        const start = performance.now();
        const duration = 520; // ms (snappy but visible)

        const step = (now: number) => {
            const raw = (now - start) / duration;
            const t = Math.max(0, Math.min(1, raw));
            setFly((prev) => (prev ? { ...prev, t } : prev));

            if (t < 1) raf = requestAnimationFrame(step);
            else {
                // End: pop receiver
                setPopPlayerId(fly.toId);
                window.setTimeout(() => setPopPlayerId(null), 420);
                // cleanup fly
                window.setTimeout(() => setFly(null), 60);
            }
        };

        raf = requestAnimationFrame(step);
        return () => cancelAnimationFrame(raf);
    }, [fly?.nonce]); // re-run per animation

    // Flying potato render data
    const flyRender = useMemo(() => {
        if (!fly) return null;

        const from = getPx(fly.fromId);
        const to = getPx(fly.toId);
        const el = containerRef.current;
        if (!from || !to || !el) return null;

        const rect = el.getBoundingClientRect();

        // Points in local container coordinates
        const p0 = { x: from.x, y: from.y };
        const p2 = { x: to.x, y: to.y };

        // control point: mid + lift upward a bit (nice arc)
        const mid = { x: (p0.x + p2.x) / 2, y: (p0.y + p2.y) / 2 };
        const dx = p2.x - p0.x;
        const dy = p2.y - p0.y;
        const dist = Math.max(1, Math.hypot(dx, dy));

        // lift scales with distance (cap)
        const lift = Math.min(120, 0.28 * dist);
        const p1 = { x: mid.x, y: mid.y - lift };

        const t = easeInOutCubic(fly.t);
        const p = bezier(p0, p1, p2, t);

        // rotation based on motion direction
        const pNext = bezier(p0, p1, p2, Math.min(1, t + 0.02));
        const ang = Math.atan2(pNext.y - p.y, pNext.x - p.x);

        // slight scale pulse during flight
        const scale = 1 + Math.sin(Math.PI * t) * 0.12;

        // convert to local pos within container
        return {
            x: p.x,
            y: p.y,
            rot: ang,
            scale,
            // for trail opacity
            t,
            w: rect.width,
            h: rect.height,
            p0,
            p2,
            p1,
        };
    }, [fly, players, positions]);

    return (
        <div ref={containerRef} className="ringWrap">
            {/* Your existing ring UI goes here (avatars etc.) */}
            {/* Keep your current layout; only add the overlay layers below */}

            {/* Pass overlay */}
            {flyRender ? (
                <div className="passOverlay" aria-hidden>
                    {/* trail line using an SVG */}
                    <svg className="trailSvg" width="100%" height="100%">
                        <path
                            d={`M ${flyRender.p0.x} ${flyRender.p0.y} Q ${flyRender.p1.x} ${flyRender.p1.y} ${flyRender.p2.x} ${flyRender.p2.y}`}
                            className="trailPath"
                            style={{ strokeDashoffset: `${(1 - flyRender.t) * 220}` }}
                        />
                    </svg>

                    {/* flying potato */}
                    <div
                        className="potato"
                        style={{
                            left: flyRender.x,
                            top: flyRender.y,
                            transform: `translate(-50%, -50%) rotate(${flyRender.rot}rad) scale(${flyRender.scale})`,
                            opacity: 1,
                        }}
                    >
                        🥔
                        <span className="potatoGlow" />
                    </div>
                </div>
            ) : null}

            {/* Receiver pop highlight */}
            {popPlayerId ? (
                <div
                    className="receiverPop"
                    style={(() => {
                        const p = getPx(popPlayerId);
                        if (!p) return { display: "none" } as React.CSSProperties;
                        return {
                            left: p.x,
                            top: p.y,
                            transform: "translate(-50%, -50%)",
                        };
                    })()}
                    aria-hidden
                />
            ) : null}

            <style>{`
        .ringWrap{
          position: relative;
          width: 100%;
          height: 100%;
        }

        .passOverlay{
          position:absolute;
          inset:0;
          pointer-events:none;
          z-index: 50;
        }

        .trailSvg{
          position:absolute;
          inset:0;
        }

        .trailPath{
          fill: none;
          stroke: rgba(255,255,255,0.45);
          stroke-width: 3.5;
          stroke-linecap: round;
          filter: drop-shadow(0 10px 20px rgba(0,0,0,0.25));
          stroke-dasharray: 220;
          transition: stroke-dashoffset 80ms linear;
          opacity: .85;
        }

        .potato{
          position:absolute;
          width: 46px;
          height: 46px;
          display:grid;
          place-items:center;
          font-size: 28px;
          border-radius: 999px;
          background: rgba(0,0,0,0.28);
          border: 1px solid rgba(255,255,255,0.16);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
          box-shadow: 0 18px 60px rgba(0,0,0,0.28), inset 0 1px 0 rgba(255,255,255,0.14);
        }

        .potatoGlow{
          position:absolute;
          inset:-18px;
          border-radius: 999px;
          background: radial-gradient(circle at 50% 50%, rgba(255,214,10,0.22), rgba(255,149,0,0.14), transparent 70%);
          filter: blur(14px);
          opacity: .95;
          pointer-events:none;
        }

        .receiverPop{
          position:absolute;
          width: 110px;
          height: 110px;
          border-radius: 999px;
          background: radial-gradient(circle at 50% 50%, rgba(255,214,10,0.18), rgba(255,45,85,0.10), transparent 70%);
          filter: blur(10px);
          animation: pop 420ms cubic-bezier(.2,1,.2,1) both;
          z-index: 40;
          pointer-events:none;
        }

        @keyframes pop{
          0%{ transform: translate(-50%,-50%) scale(.65); opacity: 0; }
          50%{ transform: translate(-50%,-50%) scale(1.05); opacity: 1; }
          100%{ transform: translate(-50%,-50%) scale(.92); opacity: 0; }
        }
      `}</style>
        </div>
    );
}