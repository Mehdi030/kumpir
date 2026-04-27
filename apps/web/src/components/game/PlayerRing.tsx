"use client";

import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";

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
    holderPlayerId?: string | null;
    mePlayerId?: string | null;
    passEvent: PassEvent | null;
    /** Player IDs that just got eliminated (animated burst). */
    explodedPlayerId?: string | null;
};

function initialsFor(name: string): string {
    const parts = name.trim().split(/\s+/);
    const first = parts[0]?.[0] ?? "?";
    const second = parts[1]?.[0] ?? "";
    return (first + second).toUpperCase().slice(0, 2);
}

/** Stable hue per player_id so avatar colors stay consistent across renders. */
function hueFor(id: string): number {
    let h = 0;
    for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
    return h % 360;
}

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

export function PlayerRing({ players, passEvent, holderPlayerId = null, mePlayerId = null, explodedPlayerId = null }: Props) {
    const containerRef = useRef<HTMLDivElement | null>(null);

    // Container size in state so we don't read refs during render
    const [size, setSize] = useState<{ w: number; h: number }>({ w: 0, h: 0 });

    useEffect(() => {
        const el = containerRef.current;
        if (!el) return;

        const measure = () => {
            const rect = el.getBoundingClientRect();
            setSize({ w: rect.width, h: rect.height });
        };
        measure();

        const ro = new ResizeObserver(measure);
        ro.observe(el);
        return () => ro.disconnect();
    }, []);

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

    // Convert relative coords to px coords using state-tracked size (no ref reads during render)
    const getPx = useCallback(
        (id: string): Pt | null => {
            const rel = positions.get(id);
            if (!rel) return null;
            if (size.w <= 0 || size.h <= 0) return null;

            const minSide = Math.min(size.w, size.h);
            const cx = size.w / 2;
            const cy = size.h / 2;
            const r = minSide * 0.38;

            return {
                x: cx + rel.x * r,
                y: cy + rel.y * r,
            };
        },
        [positions, size.w, size.h]
    );

    // Trigger nicer animation on passEvent
    useEffect(() => {
        if (!passEvent) return;

        if (reduceMotion) {
            // pop receiver briefly (defer setState off effect body)
            const onShow = window.setTimeout(() => setPopPlayerId(passEvent.toPlayerId), 0);
            const onHide = window.setTimeout(() => setPopPlayerId(null), 380);
            return () => {
                window.clearTimeout(onShow);
                window.clearTimeout(onHide);
            };
        }

        // start fly (deferred so the effect doesn't synchronously setState)
        const onStart = window.setTimeout(
            () =>
                setFly({
                    nonce: passEvent.nonce,
                    fromId: passEvent.fromPlayerId,
                    toId: passEvent.toPlayerId,
                    t: 0,
                }),
            0
        );
        return () => window.clearTimeout(onStart);
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
        if (!from || !to) return null;

        const p0 = { x: from.x, y: from.y };
        const p2 = { x: to.x, y: to.y };

        const mid = { x: (p0.x + p2.x) / 2, y: (p0.y + p2.y) / 2 };
        const dx = p2.x - p0.x;
        const dy = p2.y - p0.y;
        const dist = Math.max(1, Math.hypot(dx, dy));

        const lift = Math.min(120, 0.28 * dist);
        const p1 = { x: mid.x, y: mid.y - lift };

        const t = easeInOutCubic(fly.t);
        const p = bezier(p0, p1, p2, t);

        const pNext = bezier(p0, p1, p2, Math.min(1, t + 0.02));
        const ang = Math.atan2(pNext.y - p.y, pNext.x - p.x);

        const scale = 1 + Math.sin(Math.PI * t) * 0.12;

        return {
            x: p.x,
            y: p.y,
            rot: ang,
            scale,
            t,
            w: size.w,
            h: size.h,
            p0,
            p2,
            p1,
        };
    }, [fly, getPx, size.w, size.h]);

    const popRender = useMemo(() => {
        if (!popPlayerId) return null;
        return getPx(popPlayerId);
    }, [popPlayerId, getPx]);

    return (
        <div ref={containerRef} className="ringWrap">
            {/* Player avatars positioned around the ring */}
            {players.map((p) => {
                const pos = getPx(p.player_id);
                if (!pos) return null;

                const isHolder = !!holderPlayerId && p.player_id === holderPlayerId;
                const isMe = !!mePlayerId && p.player_id === mePlayerId;
                const isExploded = !!explodedPlayerId && p.player_id === explodedPlayerId;
                const hue = hueFor(p.player_id);

                return (
                    <div
                        key={p.player_id}
                        className={`seat ${isHolder ? "holder" : ""} ${isMe ? "me" : ""} ${!p.is_alive ? "dead" : ""} ${isExploded ? "exploded" : ""}`}
                        style={{
                            left: pos.x,
                            top: pos.y,
                            background: `radial-gradient(circle at 30% 30%, hsl(${hue},85%,68%), hsl(${(hue + 30) % 360},75%,42%))`,
                        }}
                        aria-label={p.name}
                        title={p.name}
                    >
                        <span className="seatInitials">{initialsFor(p.name)}</span>
                        <span className="seatName">
                            {p.name}
                            {isMe ? " (du)" : ""}
                        </span>
                        {isHolder ? <span className="seatBadge" aria-hidden>🥔</span> : null}
                        {!p.is_alive ? <span className="seatDeadOverlay" aria-hidden>💀</span> : null}
                        {isExploded ? <span className="seatBoom" aria-hidden>💥</span> : null}
                    </div>
                );
            })}

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
            {popPlayerId && popRender ? (
                <div
                    className="receiverPop"
                    style={{
                        left: popRender.x,
                        top: popRender.y,
                        transform: "translate(-50%, -50%)",
                    }}
                    aria-hidden
                />
            ) : null}

            <style>{`
        .ringWrap{
          position: relative;
          width: 100%;
          height: 100%;
        }

        .seat{
          position:absolute;
          width: 64px;
          height: 64px;
          border-radius: 999px;
          transform: translate(-50%, -50%);
          display: grid;
          place-items: center;
          color: rgba(255,255,255,0.96);
          font-weight: 1000;
          font-size: 18px;
          letter-spacing: 0.4px;
          border: 2px solid rgba(255,255,255,0.18);
          box-shadow: 0 14px 40px rgba(0,0,0,0.32), inset 0 1px 0 rgba(255,255,255,0.18);
          z-index: 30;
          transition: transform .25s cubic-bezier(.2,1,.2,1), box-shadow .25s ease, border-color .25s ease, opacity .25s ease;
        }
        .seat .seatInitials{
          text-shadow: 0 4px 14px rgba(0,0,0,0.4);
          user-select: none;
        }
        .seat .seatName{
          position: absolute;
          top: calc(100% + 6px);
          left: 50%;
          transform: translateX(-50%);
          font-size: 11px;
          font-weight: 900;
          letter-spacing: 0.2px;
          padding: 2px 8px;
          border-radius: 999px;
          background: rgba(0,0,0,0.42);
          border: 1px solid rgba(255,255,255,0.10);
          white-space: nowrap;
          max-width: 130px;
          overflow: hidden;
          text-overflow: ellipsis;
          opacity: 0.92;
        }
        .seat.me{
          border-color: rgba(34,211,238,0.78);
          box-shadow:
            0 14px 50px rgba(0,0,0,0.35),
            0 0 0 4px rgba(34,211,238,0.18),
            inset 0 1px 0 rgba(255,255,255,0.18);
        }
        .seat.holder{
          transform: translate(-50%, -50%) scale(1.18);
          border-color: rgba(255,214,10,0.92);
          box-shadow:
            0 18px 60px rgba(0,0,0,0.40),
            0 0 0 5px rgba(255,149,0,0.22),
            0 0 36px rgba(255,90,40,0.55),
            inset 0 1px 0 rgba(255,255,255,0.20);
          animation: seatHolderPulse 1.4s ease-in-out infinite;
        }
        .seat.dead{
          opacity: 0.34;
          filter: grayscale(0.9);
        }
        .seat .seatBadge{
          position: absolute;
          top: -10px;
          right: -10px;
          background: rgba(0,0,0,0.62);
          border: 1px solid rgba(255,255,255,0.18);
          border-radius: 999px;
          padding: 2px 6px;
          font-size: 16px;
          line-height: 1;
          box-shadow: 0 6px 20px rgba(0,0,0,0.32);
        }
        .seat .seatDeadOverlay{
          position: absolute;
          inset: 0;
          display: grid;
          place-items: center;
          font-size: 26px;
          background: rgba(0,0,0,0.32);
          border-radius: 999px;
        }
        .seat .seatBoom{
          position: absolute;
          inset: -16px;
          display: grid;
          place-items: center;
          font-size: 56px;
          pointer-events: none;
          animation: seatBoom 700ms cubic-bezier(.2,1,.2,1) both;
        }
        .seat.exploded{
          animation: seatShake 700ms cubic-bezier(.36,.07,.19,.97) both;
        }
        @keyframes seatHolderPulse{
          0%,100% { box-shadow: 0 18px 60px rgba(0,0,0,0.40), 0 0 0 5px rgba(255,149,0,0.20), 0 0 30px rgba(255,90,40,0.45), inset 0 1px 0 rgba(255,255,255,0.20); }
          50%     { box-shadow: 0 22px 70px rgba(0,0,0,0.46), 0 0 0 6px rgba(255,149,0,0.34), 0 0 50px rgba(255,90,40,0.75), inset 0 1px 0 rgba(255,255,255,0.22); }
        }
        @keyframes seatBoom{
          0%   { opacity: 0; transform: scale(0.5); }
          40%  { opacity: 1; transform: scale(1.4); }
          100% { opacity: 0; transform: scale(1.8); }
        }
        @keyframes seatShake{
          0%,100% { transform: translate(-50%, -50%); }
          20%     { transform: translate(calc(-50% - 6px), calc(-50% - 4px)); }
          40%     { transform: translate(calc(-50% + 6px), calc(-50% + 3px)); }
          60%     { transform: translate(calc(-50% - 4px), calc(-50% + 5px)); }
          80%     { transform: translate(calc(-50% + 4px), calc(-50% - 4px)); }
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