"use client";

import { KumpirPotato } from "@/components/game/KumpirPotato";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
    ready?: boolean;
    song_points?: number;
};

type DisconnectedIds = Set<string> | string[];

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
    /** Player IDs whose last_seen_at heartbeat is stale (looks disconnected). */
    disconnectedIds?: DisconnectedIds;
    /** 0..1 -- wie weit die Zündschnur schon abgebrannt ist (1 = Explosion). */
    heat?: number;
    /** Weitergabe-Richtung: 1 = Sitzreihenfolge vorwärts, -1 = rückwärts (Rache-Pass). */
    direction?: number;
    /** "Als Nächstes"-Markierung am nächsten Spieler: nur für den Halter und Ausgeschiedene (Überraschungseffekt). */
    showNext?: boolean;
};

const TILT_DEG = 48;

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

function fmtPts(n: number): string {
    return Number.isInteger(n) ? String(n) : n.toFixed(1);
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

export function PlayerRing({
    players,
    passEvent,
    holderPlayerId = null,
    mePlayerId = null,
    explodedPlayerId = null,
    disconnectedIds,
    heat = 0,
    direction = 1,
    showNext = false,
}: Props) {
    const isDisconnected = useCallback(
        (id: string) => (disconnectedIds instanceof Set ? disconnectedIds.has(id) : (disconnectedIds ?? []).includes(id)),
        [disconnectedIds]
    );

    const containerRef = useRef<HTMLDivElement | null>(null);

    // Container size in state so we don't read refs during render
    const [size, setSize] = useState<{ w: number; h: number }>({ w: 0, h: 0 });
    // Tischdurchmesser: wächst mit dem Bildschirm, aber nie so groß, dass die
    // Namensschilder an den Seiten abgeschnitten werden.
    const narrow = size.w > 0 && size.w < 520;
    const tableSize = Math.max(narrow ? 200 : 240, Math.min(Math.min(size.w, size.h) * (narrow ? 0.7 : 0.66), size.h * 0.56, 520));
    // Tischmitte: unter der Info-Leiste oben (+ Platz für Sitz und "AM ZUG"-Schild am hinteren Rand).
    // Projizierte halbe Tischtiefe ~ 0.455 * Größe * cos(Neigung) ≈ 0.305 * Größe.
    const cyPx = Math.max(size.h * 0.26, (narrow ? 178 : 172) + tableSize * 0.305);
    // Unterkante (vorderer Sitz + Name) -> Antwort-Box der Spielseite beginnt darunter (CSS-Variable --ringBottom)
    const ringBottom = Math.round(cyPx + tableSize * 0.305 + (narrow ? 66 : 92));
    // Auf dem Handy: kleinere Sitze und Schilder, sonst überlappen sie sich am kleinen Tisch.
    const seatPx = narrow ? 38 : 56;

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

    useEffect(() => {
        if (size.h <= 0) return;
        document.documentElement.style.setProperty("--ringBottom", `${ringBottom}px`);
        return () => {
            document.documentElement.style.removeProperty("--ringBottom");
        };
    }, [ringBottom, size.h]);

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

    // Sitzplätze am Tisch: NUR lebende Spieler (plus wer GERADE explodiert,
    // damit die Explosion noch an der alten Position abspielen kann, bevor
    // der Platz verschwindet). Die Anzahl bestimmt den Winkelabstand; fliegt
    // jemand raus, rücken die übrigen per CSS-Transition flüssig nach.
    const seatedPlayers = useMemo(
        () => players.filter((p) => p.is_alive || p.player_id === explodedPlayerId),
        [players, explodedPlayerId]
    );

    const positions = useMemo(() => {
        const n = seatedPlayers.length;
        const map = new Map<string, Pt>();
        if (n === 0) return map;

        const step = (Math.PI * 2) / n;
        // Jeder sieht sich selbst unten (Winkel 90°), alle anderen in
        // derselben Reihenfolge um ihn herum -- für alle Spieler identisch.
        const meIdx = mePlayerId ? seatedPlayers.findIndex((p) => p.player_id === mePlayerId) : -1;
        const startAngle = Math.PI / 2 - Math.max(0, meIdx) * step;

        for (let i = 0; i < n; i++) {
            const a = startAngle + i * step;
            map.set(seatedPlayers[i]!.player_id, { x: Math.cos(a), y: Math.sin(a) });
        }
        return map;
    }, [seatedPlayers, mePlayerId]);

    // Convert relative coords to px coords using state-tracked size (no ref reads during render)
    const getPx = useCallback(
        (id: string): Pt | null => {
            const rel = positions.get(id);
            if (!rel) return null;
            if (size.w <= 0 || size.h <= 0) return null;

            const cx = size.w / 2;
            // Oberhalb der Antwort-Box (.hud) statt exakt Bildschirmmitte.
            const cy = cyPx;
            // Sitze direkt am Tischrand (wie Spieler, die am Tisch sitzen).
            const r = tableSize * 0.455;

            return { x: cx + rel.x * r, y: cy + rel.y * r };
        },
        [positions, size.w, size.h, tableSize, cyPx]
    );

    // Trigger nicer animation on passEvent
    useEffect(() => {
        if (!passEvent) return;

        if (reduceMotion) {
            const onShow = window.setTimeout(() => setPopPlayerId(passEvent.toPlayerId), 0);
            const onHide = window.setTimeout(() => setPopPlayerId(null), 380);
            return () => {
                window.clearTimeout(onShow);
                window.clearTimeout(onHide);
            };
        }

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
        const duration = 520;

        const step = (now: number) => {
            const raw = (now - start) / duration;
            const t = Math.max(0, Math.min(1, raw));
            setFly((prev) => (prev ? { ...prev, t } : prev));

            if (t < 1) raf = requestAnimationFrame(step);
            else {
                setPopPlayerId(fly.toId);
                window.setTimeout(() => setPopPlayerId(null), 420);
                window.setTimeout(() => setFly(null), 60);
            }
        };

        raf = requestAnimationFrame(step);
        return () => cancelAnimationFrame(raf);
        // Keyed on fly.nonce only: including the full `fly` object would
        // restart the animation on every state update.
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [fly?.nonce]);

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

        const scale = 1 + Math.sin(Math.PI * t) * 0.35;
        // Flughöhe: Kartoffel steigt in der Mitte des Wurfs über den Tisch.
        const height = Math.sin(Math.PI * t) * 90;

        return { x: p.x, y: p.y, scale, height, t, p0, p2, p1 };
    }, [fly, getPx]);

    const holderPos = holderPlayerId ? getPx(holderPlayerId) : null;

    // Nachbilder der fliegenden Kumpir (Bewegungsunschärfe): 3 verblassende Kopien auf der Flugbahn.
    const flyGhosts = useMemo(() => {
        if (!flyRender || !fly) return [] as { x: number; y: number; height: number; rot: number }[];
        return [1, 2, 3].map((k) => {
            const tt = Math.max(0, fly.t - k * 0.07);
            const e = easeInOutCubic(tt);
            const pt = bezier(flyRender.p0, flyRender.p1, flyRender.p2, e);
            return { x: pt.x, y: pt.y, height: Math.sin(Math.PI * e) * 90, rot: tt * 540 };
        });
    }, [flyRender, fly]);
    const potatoPx = narrow ? 40 : 62;

    // Wer bekommt die Kartoffel als Nächstes? (nur für Halter/Ausgeschiedene sichtbar)
    const nextId = useMemo(() => {
        if (!showNext || !holderPlayerId) return null;
        const alive = players.filter((p) => p.is_alive);
        const n = alive.length;
        if (n < 3) return null; // im Duell ist es eh klar
        const hi = alive.findIndex((p) => p.player_id === holderPlayerId);
        if (hi < 0) return null;
        return alive[(hi + (direction < 0 ? -1 : 1) + n) % n]?.player_id ?? null;
    }, [players, holderPlayerId, direction, showNext]);

    const popRender = useMemo(() => {
        if (!popPlayerId) return null;
        return getPx(popPlayerId);
    }, [popPlayerId, getPx]);

    // Pulsierende Zündschnur: Tempo und Stärke steigen mit der Hitze. In
    // Stufen quantisiert, damit sich die Animationsdauer nicht jeden Frame
    // ändert (würde die Animation immer neu starten = ruckeln).
    const heatLevel = Math.round(Math.max(0, Math.min(1, heat)) * 10) / 10;
    const pulseSec = (2.6 - 2.3 * Math.pow(heatLevel, 1.15)).toFixed(2);
    const pulseAmp = (0.1 + 0.9 * heatLevel).toFixed(2);

    const hot = heat > 0.66;

    return (
        <div
            ref={containerRef}
            className={`ringWrap ${hot ? "ringHot" : ""} ${narrow ? "ringNarrow" : ""}`}
            style={{
                ["--seat" as string]: `${seatPx}px`,
                ["--potatoPx" as string]: `${potatoPx}px`,
                ["--tilt" as string]: `${TILT_DEG}deg`,
                ["--pulse" as string]: `${pulseSec}s`,
                ["--amp" as string]: pulseAmp,
            }}
        >
            <div className="tableTilt">
                {/* ---------- Tisch: ruhige dunkle Platte, feiner Metallrand, Glut am Rand = Zündschnur ---------- */}
                <div className="tableBase" aria-hidden style={{ top: cyPx, width: tableSize, height: tableSize }}>
                    <div className="tShadow" />
                    <div className="tEdge tEdge2" />
                    <div className="tEdge tEdge1" />
                    <div className="tRim" />
                    <div className="tTop" />
                    <div className="tInlay" />
                    <div className="tCenter" />
                    <div className="tGloss" />
                    <div className="tPulse" />
                </div>

                {/* Kontakt-Schatten der Sitze */}
                {seatedPlayers.map((p) => {
                    const pos = getPx(p.player_id);
                    if (!pos) return null;
                    return <div key={`sh-${p.player_id}`} className="seatShadow" style={{ left: pos.x, top: pos.y }} aria-hidden />;
                })}
                {holderPos ? <div className="holderSpot" style={{ left: holderPos.x, top: holderPos.y }} aria-hidden /> : null}

                {/* ---------- Spieler: Kreis am Tischrand, Name direkt darunter ---------- */}
                {players.map((p) => {
                    const pos = getPx(p.player_id);
                    if (!pos) return null;

                    const isHolder = !!holderPlayerId && p.player_id === holderPlayerId;
                    const isMe = !!mePlayerId && p.player_id === mePlayerId;
                    const isNext = !isHolder && p.player_id === nextId;
                    const isExploded = !!explodedPlayerId && p.player_id === explodedPlayerId;
                    const isStale = p.is_alive && isDisconnected(p.player_id);
                    const pts = p.song_points ?? 0;

                    return (
                        <div
                            key={p.player_id}
                            className={`seat ${isHolder ? "holder" : ""} ${isMe ? "me" : ""} ${isNext ? "next" : ""} ${!p.is_alive ? "dead" : ""} ${isExploded ? "exploded" : ""}`}
                            style={{ left: pos.x, top: pos.y, ["--h" as string]: hueFor(p.player_id) }}
                            aria-label={`${p.name}${isHolder ? " (am Zug)" : ""}${isMe ? " (du)" : ""}`}
                            title={p.name}
                        >
                            {isHolder ? (
                                <span className="seatBadge">
                                    {!flyRender ? (
                                        <span className="badgePotato">
                                            <KumpirPotato size={narrow ? 26 : 38} heat={heat} />
                                        </span>
                                    ) : null}
                                    AM ZUG
                                </span>
                            ) : isNext ? <span className="seatBadge nextBadge">als Nächstes</span> : null}
                            <span className="seatDisc">
                                <span className="seatInitials">{initialsFor(p.name)}</span>
                                {!p.is_alive ? (
                                    <span className="seatDeadOverlay" aria-hidden>
                                        💀
                                    </span>
                                ) : null}
                            </span>
                            <span className="seatName">
                                <span className="seatNameText">{p.name}</span>
                                {isMe ? <span className="seatMe">du</span> : null}
                                {pts > 0 ? <span className="seatPts">♪ {fmtPts(pts)}</span> : null}
                            </span>
                            {isExploded ? (
                                <span className="seatBoom" aria-hidden>
                                    <span className="boomFlash" />
                                    <span className="boomRing" />
                                    <span className="boomEmoji">💥</span>
                                </span>
                            ) : null}
                            {isStale ? (
                                <span className="seatStale" title="Verbindung verloren?" aria-label="Verbindung verloren?">
                                    📡
                                </span>
                            ) : null}
                        </div>
                    );
                })}

                {/* Wurf-Animation */}
                {flyRender ? (
                    <div className="passOverlay" aria-hidden>
                        <svg className="trailSvg" width="100%" height="100%">
                            <path
                                d={`M ${flyRender.p0.x} ${flyRender.p0.y} Q ${flyRender.p1.x} ${flyRender.p1.y} ${flyRender.p2.x} ${flyRender.p2.y}`}
                                className="trailPath"
                                style={{ strokeDashoffset: `${(1 - flyRender.t) * 220}` }}
                            />
                        </svg>
                        {flyGhosts.map((g, k) => (
                            <div
                                key={k}
                                className="potatoGhost"
                                style={{
                                    left: g.x,
                                    top: g.y,
                                    opacity: 0.32 - k * 0.09,
                                    transform: `translate(-50%, -50%) translateZ(${60 + g.height}px) rotateX(-${TILT_DEG}deg) scale(${0.9 - k * 0.1}) rotate(${g.rot}deg)`,
                                }}
                            >
                                <KumpirPotato size={potatoPx} heat={0} />
                            </div>
                        ))}
                        <div className="potatoShadow" style={{ left: flyRender.x, top: flyRender.y, opacity: 0.6 - flyRender.height / 220 }} />
                        <div
                            className="potatoFly"
                            style={{
                                left: flyRender.x,
                                top: flyRender.y,
                                transform: `translate(-50%, -50%) translateZ(${60 + flyRender.height}px) rotateX(-${TILT_DEG}deg) scale(${flyRender.scale}) rotate(${flyRender.t * 540}deg)`,
                            }}
                        >
                            <KumpirPotato size={potatoPx} heat={heat} />
                        </div>
                    </div>
                ) : null}

                {popPlayerId && popRender ? <div className="receiverPop" style={{ left: popRender.x, top: popRender.y }} aria-hidden /> : null}
            </div>

            <style>{`
        .ringWrap{
          position: fixed;
          inset: 0;
          z-index: 2;
          pointer-events: none;
          perspective: 1400px;
          perspective-origin: 50% 30%;
        }
        .tableTilt{
          position:absolute;
          inset:0;
          transform-style: preserve-3d;
          transform: rotateX(var(--tilt));
        }

        /* ===== Tisch (Ebenen gestapelt in Z) ===== */
        .tableBase{
          position:absolute;
          left:50%;
          transform: translate(-50%,-50%);
          transform-style: preserve-3d;
        }
        .tableBase > *{ position:absolute; inset:0; border-radius:50%; }
        .tShadow{
          transform: translateZ(-60px) scale(1.1);
          background: radial-gradient(circle, rgba(0,0,0,.6) 0%, rgba(0,0,0,.3) 55%, transparent 72%);
          filter: blur(22px);
        }
        /* Tischkante (Dicke) */
        .tEdge1{ transform: translateZ(-8px); background: linear-gradient(180deg, #2c2f3a, #14161d); }
        .tEdge2{ transform: translateZ(-18px); background: #0a0b10; box-shadow: 0 14px 40px rgba(0,0,0,.55); }
        /* feiner Metallrand */
        .tRim{
          background: conic-gradient(from 210deg, #9aa1b3, #eef1f7 14%, #7b8194 30%, #cfd4e0 46%, #686e80 62%, #e2e6ef 78%, #9aa1b3);
          box-shadow: inset 0 0 0 1px rgba(255,255,255,.4), 0 0 30px rgba(0,0,0,.45);
        }
        /* Tischplatte: tiefes Anthrazit mit ganz feiner Struktur */
        .tTop{
          inset: 2.6%;
          transform: translateZ(1px);
          background:
            radial-gradient(circle at 50% 42%, rgba(255,255,255,.07), transparent 58%),
            repeating-radial-gradient(circle at 50% 50%, rgba(255,255,255,.018) 0 1px, transparent 1px 4px),
            radial-gradient(circle at 50% 50%, #23252f 0%, #15161d 60%, #0b0c11 100%);
          box-shadow: inset 0 0 0 1px rgba(0,0,0,.7), inset 0 18px 40px rgba(0,0,0,.45);
        }
        /* dünne goldene Zierlinie */
        .tInlay{
          inset: 11%;
          transform: translateZ(2px);
          border: 1.5px solid rgba(255,206,120,.32);
          box-shadow: 0 0 0 6px rgba(255,206,120,.035);
        }
        /* Mitte: kleines Kumpir-Emblem */
        .tCenter{
          inset: 41%;
          transform: translateZ(2.5px);
          background: radial-gradient(circle at 40% 32%, #3a2a17, #1a130b 70%);
          box-shadow: 0 0 0 1.5px rgba(255,206,120,.45), inset 0 2px 6px rgba(0,0,0,.6);
        }
        .tCenter::after{
          content:"🥔"; position:absolute; inset:0; display:grid; place-items:center;
          font-size: calc(var(--seat, 56px) * .5); opacity: .55; filter: grayscale(.2);
        }
        .tGloss{
          transform: translateZ(4px);
          background: radial-gradient(ellipse 62% 36% at 36% 18%, rgba(255,255,255,.10), transparent 70%);
          pointer-events: none;
        }
        /* Zündschnur: Glut am Rand, je näher die Explosion, desto schneller und heller */
        .tPulse{
          inset: -0.5%;
          transform: translateZ(3px);
          pointer-events: none;
          animation: fusePulse var(--pulse, 2.6s) ease-in-out infinite;
        }
        @keyframes fusePulse{
          0%,100%{ box-shadow: 0 0 calc(8px + 14px * var(--amp, .1)) calc(1px + 2px * var(--amp, .1)) rgba(255,110,40, calc(.08 + .25 * var(--amp, .1))); }
          50%{ box-shadow: 0 0 calc(18px + 50px * var(--amp, .1)) calc(4px + 10px * var(--amp, .1)) rgba(255,80,25, calc(.18 + .6 * var(--amp, .1))); }
        }
        .ringHot .tRim{ background: conic-gradient(from 210deg, #ffb27a, #fff1e0 14%, #d9692b 30%, #ffd2a8 46%, #b5481c 62%, #ffe2c4 78%, #ffb27a); }

        /* ===== Sitze ===== */
        .seatShadow{
          position:absolute;
          width: calc(var(--seat) + 10px); height: calc(var(--seat) + 10px);
          transform: translate(-50%,-50%) translateZ(5px);
          border-radius: 50%;
          background: radial-gradient(circle, rgba(0,0,0,.55) 0%, rgba(0,0,0,.2) 55%, transparent 72%);
          transition: left .45s cubic-bezier(.2,1,.2,1), top .45s cubic-bezier(.2,1,.2,1);
        }
        .holderSpot{
          position:absolute;
          width: calc(var(--seat) * 2.6); height: calc(var(--seat) * 2.6);
          transform: translate(-50%,-50%) translateZ(5px);
          border-radius: 50%;
          background: radial-gradient(circle, rgba(255,190,60,.30) 0%, rgba(255,140,30,.10) 50%, transparent 70%);
          transition: left .5s cubic-bezier(.2,1,.2,1), top .5s cubic-bezier(.2,1,.2,1);
          animation: spotBreath 1.6s ease-in-out infinite;
        }
        @keyframes spotBreath{ 0%,100%{ opacity:.7; } 50%{ opacity:1; } }

        /* Sitz = aufrechter Aufsteller (Billboard) mit Kreis, Name darunter, ggf. Schild darüber */
        .seat{
          position:absolute;
          width: var(--seat); height: var(--seat);
          transform: translate(-50%, -50%) translateZ(52px) rotateX(calc(var(--tilt) * -1));
          transform-origin: 50% 50%;
          z-index: 30;
          transition: left .45s cubic-bezier(.2,1,.2,1), top .45s cubic-bezier(.2,1,.2,1), transform .3s cubic-bezier(.2,1,.2,1);
        }
        .seatDisc{
          position:absolute; inset:0; border-radius:50%;
          display:grid; place-items:center;
          color:#fff; font-family: var(--font-display); font-weight: 800; font-size: calc(var(--seat) * .32); letter-spacing:.3px;
          background: radial-gradient(circle at 34% 28%, hsl(var(--h) 70% 62%), hsl(var(--h) 55% 38%) 62%, hsl(var(--h) 50% 24%));
          box-shadow: 0 0 0 2.5px rgba(255,255,255,.75), 0 0 0 4px rgba(0,0,0,.35), 0 10px 20px rgba(0,0,0,.45), inset 0 2px 4px rgba(255,255,255,.35), inset 0 -6px 10px rgba(0,0,0,.35);
          transition: box-shadow .25s ease;
        }
        .seatInitials{ text-shadow: 0 2px 5px rgba(0,0,0,.5); user-select:none; }
        .seatName{
          position:absolute; left:50%; top: calc(100% + 7px);
          transform: translateX(-50%);
          display:flex; align-items:center; gap:6px;
          max-width: 190px;
          padding: 4px 11px;
          border-radius: 999px;
          background: rgba(10,12,20,.86);
          border: 1px solid rgba(255,255,255,.18);
          box-shadow: 0 6px 14px rgba(0,0,0,.4);
          color:#fff; font-size: 14px; font-weight: 800; white-space: nowrap;
        }
        .seatNameText{ overflow:hidden; text-overflow: ellipsis; min-width:0; }
        .seatMe{ flex:none; font-size: 10.5px; font-weight: 900; padding: 1px 6px; border-radius: 999px; background: rgba(34,211,238,.2); border: 1px solid rgba(34,211,238,.7); color: #c4f6ff; text-transform: uppercase; letter-spacing: .5px; }
        .seatPts{ flex:none; font-size: 12px; font-weight: 900; color: #ffe08a; }
        .seatBadge{
          position:absolute; left:50%; bottom: calc(100% + 8px);
          transform: translateX(-50%);
          padding: 3px 10px; border-radius: 999px;
          font-size: 11px; font-weight: 950; letter-spacing: 1.2px; white-space: nowrap;
          display: inline-flex; align-items: center; gap: 6px;
          color: #3a2200; background: linear-gradient(180deg, #ffe58a, #ffb81c);
          box-shadow: 0 4px 14px rgba(255,170,30,.55), inset 0 1px 0 rgba(255,255,255,.7);
        }
        /* Die Kartoffel sitzt im "AM ZUG"-Schild des Halters (nie vom Sitz verdeckt) */
        .badgePotato{ display:inline-block; line-height:0; margin: -14px 0 -12px -8px; filter: drop-shadow(0 3px 6px rgba(0,0,0,.45)) drop-shadow(0 0 10px rgba(255,150,40,.7)); animation: badgeBob 1.2s ease-in-out infinite; }
        @keyframes badgeBob{ 0%,100%{ transform: translateY(0) rotate(-6deg); } 50%{ transform: translateY(-3px) rotate(6deg); } }
        .seatBadge.nextBadge{
          color: rgba(255,255,255,.85); background: rgba(10,12,20,.75);
          border: 1px dashed rgba(255,255,255,.45); box-shadow: none; letter-spacing: .4px; font-weight: 800;
        }

        /* Du: türkiser Ring */
        .seat.me .seatDisc{ box-shadow: 0 0 0 3px #3fe0f5, 0 0 0 5px rgba(0,0,0,.35), 0 0 18px rgba(34,211,238,.45), 0 10px 20px rgba(0,0,0,.45), inset 0 2px 4px rgba(255,255,255,.35), inset 0 -6px 10px rgba(0,0,0,.35); }
        .seat.me .seatName{ border-color: rgba(63,224,245,.75); }
        /* Am Zug: goldener Ring, größer, Name in Gold */
        .seat.holder{ transform: translate(-50%, -50%) translateZ(60px) rotateX(calc(var(--tilt) * -1)) scale(1.16); z-index: 36; }
        .seat.holder .seatDisc{ animation: holderRing 1.3s ease-in-out infinite; }
        .seat.holder .seatName{ background: linear-gradient(180deg, #7a4a06, #5a3300); border-color: rgba(255,214,10,.9); color: #fff3c4; }
        @keyframes holderRing{
          0%,100%{ box-shadow: 0 0 0 3px #ffc929, 0 0 0 6px rgba(255,170,30,.28), 0 0 22px rgba(255,150,30,.55), 0 10px 20px rgba(0,0,0,.45), inset 0 2px 4px rgba(255,255,255,.35); }
          50%{ box-shadow: 0 0 0 3px #ffe27a, 0 0 0 9px rgba(255,170,30,.18), 0 0 36px rgba(255,150,30,.8), 0 10px 20px rgba(0,0,0,.45), inset 0 2px 4px rgba(255,255,255,.35); }
        }
        /* Als Nächstes: gestrichelter Ring */
        .seat.next .seatDisc{ box-shadow: 0 0 0 2.5px rgba(255,255,255,.75), 0 0 0 6px rgba(255,255,255,.12), 0 10px 20px rgba(0,0,0,.45), inset 0 2px 4px rgba(255,255,255,.35); outline: 2px dashed rgba(255,255,255,.55); outline-offset: 5px; }

        .seat.dead{ opacity:.34; filter: grayscale(.9); }
        .seatDeadOverlay{ position:absolute; inset:0; display:grid; place-items:center; font-size: 22px; background: rgba(0,0,0,.34); border-radius: 50%; }
        .seatStale{
          position:absolute; top:-6px; right:-8px;
          background: rgba(120,20,20,.85); border: 1px solid rgba(255,255,255,.24);
          border-radius: 999px; padding: 2px 5px; font-size: 12px; line-height:1;
          animation: staleBlink 1.6s ease-in-out infinite;
        }
        @keyframes staleBlink{ 0%,100%{opacity:1;} 50%{opacity:.45;} }

        /* Handy: kleinere Schrift, Name kompakt */
        .ringNarrow .seatName{ font-size: 11.5px; padding: 2px 7px; gap: 4px; max-width: 88px; top: calc(100% + 5px); }
        .ringNarrow .seatMe{ display:none; }
        .ringNarrow .seatPts{ font-size: 10px; }
        .ringNarrow .seatBadge{ font-size: 9.5px; padding: 2px 7px; letter-spacing: .8px; }

        /* Explosion */
        .seatBoom{ position:absolute; inset:-34px; display:grid; place-items:center; pointer-events:none; }
        .boomFlash{ position:absolute; inset: 6px; border-radius: 50%; background: radial-gradient(circle, #fffbe0 0%, #ffd23f 28%, #ff7a1a 55%, rgba(255,60,0,0) 72%); animation: boomFlash 720ms cubic-bezier(.2,.9,.2,1) both; }
        .boomRing{ position:absolute; inset: 14px; border-radius: 50%; border: 4px solid rgba(255,214,120,.9); animation: boomRing 720ms cubic-bezier(.2,.9,.2,1) both; }
        .boomEmoji{ position: relative; font-size: 54px; animation: seatBoom 700ms cubic-bezier(.2,1,.2,1) both; }
        @keyframes boomFlash{ 0%{ opacity:0; transform: scale(.3); } 25%{ opacity:1; transform: scale(1.1); } 100%{ opacity:0; transform: scale(1.8); } }
        @keyframes boomRing{ 0%{ opacity:.95; transform: scale(.4); } 100%{ opacity:0; transform: scale(2.3); } }
        @keyframes seatBoom{ 0%{ opacity:0; transform: scale(.5); } 40%{ opacity:1; transform: scale(1.4); } 100%{ opacity:0; transform: scale(1.9); } }
        .seat.exploded{ animation: seatShake 700ms cubic-bezier(.36,.07,.19,.97) both; }
        @keyframes seatShake{ 0%,100%{ translate: 0 0; } 20%{ translate: -6px -4px; } 40%{ translate: 6px 3px; } 60%{ translate: -4px 5px; } 80%{ translate: 4px -4px; } }

        /* ===== Kumpir ===== */
        .potatoShadow{
          position:absolute;
          width: calc(var(--potatoPx) * .7); height: calc(var(--potatoPx) * .7);
          transform: translate(-50%,-50%) translateZ(5px) scaleY(.75);
          border-radius:50%;
          background: radial-gradient(circle, rgba(0,0,0,.6), transparent 70%);
          transition: left .5s cubic-bezier(.2,1,.2,1), top .5s cubic-bezier(.2,1,.2,1);
        }
        .potatoFly, .potatoGhost{ position:absolute; width: var(--potatoPx); height: var(--potatoPx); line-height: 0; }
        .potatoFly{ filter: drop-shadow(0 12px 16px rgba(0,0,0,.55)) drop-shadow(0 0 20px rgba(255,170,50,.85)); }
        .potatoGhost{ pointer-events:none; }
        @keyframes potatoBob{ 0%,100%{ margin-top: 0; } 50%{ margin-top: -7px; } }

        .passOverlay{ position:absolute; inset:0; pointer-events:none; z-index: 50; transform-style: preserve-3d; }
        .trailSvg{ position:absolute; inset:0; transform: translateZ(6px); }
        .trailPath{
          fill:none; stroke: rgba(255,214,120,.6); stroke-width: 3.5; stroke-linecap: round; stroke-dasharray: 220;
          filter: drop-shadow(0 0 8px rgba(255,170,50,.8));
          transition: stroke-dashoffset 80ms linear;
        }
        .receiverPop{
          position:absolute; width: 120px; height: 120px; border-radius: 999px;
          background: radial-gradient(circle, rgba(255,214,10,.4), rgba(255,45,85,.16), transparent 70%);
          filter: blur(8px);
          animation: pop 420ms cubic-bezier(.2,1,.2,1) both;
          z-index: 40;
          transform: translate(-50%,-50%) translateZ(6px);
        }
        @keyframes pop{ 0%{ opacity:0; scale:.6; } 50%{ opacity:1; scale:1.1; } 100%{ opacity:0; scale:.9; } }

        @media (prefers-reduced-motion: reduce){
          .badgePotato, .holderSpot, .seat.holder .seatDisc, .tPulse{ animation: none; }
        }
      `}</style>
        </div>
    );
}
