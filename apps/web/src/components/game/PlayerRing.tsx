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
    /** Aktuelle Runde (Eliminierungen + 1) für die Tisch-Mitte. */
    round?: number;
    /** Tempo-Faktor (1.0 = Start, steigt mit jeder Runde). */
    tempo?: number;
    /** Nur noch 2 Lebende: Duell-Finale. */
    duel?: boolean;
    /** Weitergabe-Richtung: 1 = Sitzreihenfolge vorwärts, -1 = rückwärts (Rache-Pass). */
    direction?: number;
    /** Vorschau-Linie zum nächsten Spieler: nur für den Halter und Ausgeschiedene (Überraschungseffekt). */
    showNext?: boolean;
};

const TILT_DEG = 52;
const CY = 0.27; // Tischmitte (Anteil der Höhe)

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
    round = 1,
    tempo = 1,
    duel = false,
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
    const tableSize = Math.max(narrow ? 200 : 240, Math.min(Math.min(size.w, size.h) * (narrow ? 0.7 : 0.66), 540));
    // Auf dem Handy: kleinere Sitze und Schilder, sonst überlappen sie sich am kleinen Tisch.
    const seatPx = narrow ? 34 : 54;

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
            const cy = size.h * CY;
            // Sitze auf der Filzplatte knapp innerhalb des Holzrands.
            const r = tableSize * 0.335;

            return { x: cx + rel.x * r, y: cy + rel.y * r };
        },
        [positions, size.w, size.h, tableSize]
    );

    // Namensschilder außerhalb des Tischrands (immer gut lesbar).
    const getLabelPx = useCallback(
        (id: string): { x: number; y: number; ax: number; ay: number } | null => {
            const rel = positions.get(id);
            if (!rel || size.w <= 0 || size.h <= 0) return null;
            const R = tableSize * 0.5 + (narrow ? 2 : 20);
            return { x: size.w / 2 + rel.x * R, y: size.h * CY + rel.y * R, ax: rel.x, ay: rel.y };
        },
        [positions, size.w, size.h, tableSize, narrow]
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
    const potatoPx = narrow ? 44 : 76;

    // Vorschau-Linie: wohin fliegt die Kartoffel als Nächstes?
    const nextArc = useMemo(() => {
        if (!showNext || !holderPlayerId || size.w <= 0) return null;
        const alive = players.filter((p) => p.is_alive);
        const n = alive.length;
        if (n < 2) return null;
        const hi = alive.findIndex((p) => p.player_id === holderPlayerId);
        if (hi < 0) return null;
        const step = direction < 0 ? -1 : 1;
        const next = alive[(hi + step + n) % n];
        if (!next) return null;
        const a = getPx(holderPlayerId);
        const b = getPx(next.player_id);
        if (!a || !b) return null;
        const cx = size.w / 2;
        const cy = size.h * CY;
        const mx = (a.x + b.x) / 2;
        const my = (a.y + b.y) / 2;
        const c = { x: mx + (cx - mx) * 0.5, y: my + (cy - my) * 0.5 };
        return { a, b, c };
    }, [players, holderPlayerId, direction, showNext, getPx, size.w, size.h]);

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
        <div ref={containerRef} className={`ringWrap ${hot ? "ringHot" : ""} ${narrow ? "ringNarrow" : ""}`} style={{ ["--seat" as string]: `${seatPx}px`, ["--seatH" as string]: `${Math.round(seatPx * 1.18)}px`, ["--tagFs" as string]: narrow ? "12px" : "15px", ["--tagMax" as string]: narrow ? "92px" : "210px", ["--potatoPx" as string]: narrow ? "44px" : "76px", ["--tilt" as string]: `${TILT_DEG}deg`, ["--pulse" as string]: `${pulseSec}s`, ["--amp" as string]: pulseAmp }}>
            <div className="tableTilt">
                {/* ---------- Tisch ---------- */}
                <div className="tableBase" aria-hidden style={{ top: `${CY * 100}%`, width: tableSize, height: tableSize }}>
                    <div className="tShadow" />
                    <div className="tEdge tEdge3" />
                    <div className="tEdge tEdge2" />
                    <div className="tEdge tEdge1" />
                    <div className="tRim" />
                    <div className="tNeon" />
                    <div className="tVinyl" />
                    <div className="tTracks" />
                    <div className="tSheen" />
                    <div className="tTicks" />
                    <div className="tLabel" />
                    <div className="tSpindle" />
                    <div className="tGloss" />

                    {/* Zündschnur: pulsierende Glut am Tischrand -- je näher die Explosion,
                        desto schneller und heller. */}
                    <div className="tPulse" />
                </div>

                {/* Tisch-Mitte: Runde + Tempo, aufrecht gestellt (Billboard). */}
                {size.w > 0 && !narrow ? (
                    <div className="tHub" style={{ left: size.w / 2, top: size.h * CY }}>
                        <div className="tHubRound">ZUG {round}</div>
                        <div className={`tHubTempo ${duel ? "duel" : ""}`}>
                            {duel ? "⚔ DUELL" : `⚡ Tempo ×${tempo.toFixed(1)}`}
                        </div>
                    </div>
                ) : null}

                {/* Kontakt-Schatten + Spotlight auf dem Filz */}
                {seatedPlayers.map((p) => {
                    const pos = getPx(p.player_id);
                    if (!pos) return null;
                    return <div key={`sh-${p.player_id}`} className="seatShadow" style={{ left: pos.x, top: pos.y }} aria-hidden />;
                })}
                {nextArc && !flyRender ? (
                    <svg className="nextArc" width="100%" height="100%" aria-hidden>
                        <defs>
                            <marker id="nextArrow" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
                                <path d="M0,0 L10,5 L0,10 z" fill="rgba(255,255,255,0.7)" />
                            </marker>
                        </defs>
                        <path
                            d={`M ${nextArc.a.x} ${nextArc.a.y} Q ${nextArc.c.x} ${nextArc.c.y} ${nextArc.b.x} ${nextArc.b.y}`}
                            className="nextArcPath"
                            markerEnd="url(#nextArrow)"
                        />
                    </svg>
                ) : null}
                {holderPos ? <div className="holderSpot" style={{ left: holderPos.x, top: holderPos.y }} aria-hidden /> : null}

                {/* ---------- Spieler ---------- */}
                {players.map((p) => {
                    const pos = getPx(p.player_id);
                    if (!pos) return null;

                    const isHolder = !!holderPlayerId && p.player_id === holderPlayerId;
                    const isMe = !!mePlayerId && p.player_id === mePlayerId;
                    const isExploded = !!explodedPlayerId && p.player_id === explodedPlayerId;
                    const isStale = p.is_alive && isDisconnected(p.player_id);
                    const hue = hueFor(p.player_id);

                    return (
                        <div
                            key={p.player_id}
                            className={`seat ${isHolder ? "holder" : ""} ${isMe ? "me" : ""} ${!p.is_alive ? "dead" : ""} ${isExploded ? "exploded" : ""}`}
                            style={{
                                left: pos.x,
                                top: pos.y,
                                ["--h" as string]: hue,
                            }}
                            aria-label={p.name}
                            title={p.name}
                        >
                            <span className="seatFace" aria-hidden />
                            <span className="seatGloss" aria-hidden />
                            <span className="seatInitials">{initialsFor(p.name)}</span>
                            {!p.is_alive ? <span className="seatDeadOverlay" aria-hidden>💀</span> : null}
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

                {/* ---------- Namensschilder außerhalb des Tischs ---------- */}
                {seatedPlayers.map((p) => {
                    const lp = getLabelPx(p.player_id);
                    if (!lp) return null;
                    const isHolder = !!holderPlayerId && p.player_id === holderPlayerId;
                    const isMe = !!mePlayerId && p.player_id === mePlayerId;
                    const pts = p.song_points ?? 0;
                    // Handy: Schild mittig auf den Tischrand setzen (sonst ragt es seitlich aus dem Bildschirm)
                    const tx = narrow ? (lp.ay < -0.5 ? (lp.ax < 0 ? "-90%" : "-10%") : "-50%") : lp.ay > 0.5 || lp.ay < -0.5 ? "-50%" : lp.ax > 0 ? "0%" : "-100%";
                    const ty = narrow ? (lp.ay < -0.5 ? "-110%" : lp.ay > 0.5 ? "-5%" : "-50%") : lp.ay > 0.5 ? "0%" : lp.ay < -0.5 ? "-100%" : "-50%";
                    return (
                        <div
                            key={`nm-${p.player_id}`}
                            className={`nameTag ${isHolder ? "holder" : ""} ${isMe ? "me" : ""} ${!p.is_alive ? "gone" : ""}`}
                            style={{ left: lp.x, top: lp.y, ["--tx" as string]: tx, ["--ty" as string]: ty }}
                        >
                            <span className="nameTagText">{p.name}</span>
                            {isMe ? <span className="nameTagMe">du</span> : null}
                            {pts > 0 ? <span className="nameTagPts">♪ {fmtPts(pts)}</span> : null}
                        </div>
                    );
                })}

                {/* Kumpir liegt beim aktuellen Halter, schwebt leicht und gleitet
                    beim Wechsel zum nächsten Platz; nur während der Wurf-
                    Animation wird sie ausgeblendet. */}
                {holderPos && !flyRender ? (
                    <>
                        <div className="potatoShadow" style={{ left: holderPos.x, top: holderPos.y + 30 }} aria-hidden />
                        <div className="tablePotato" style={{ left: holderPos.x, top: holderPos.y - 56 }} aria-hidden>
                            <KumpirPotato size={potatoPx} heat={heat} />
                        </div>
                    </>
                ) : null}

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
                                    top: g.y - 40,
                                    opacity: 0.32 - k * 0.09,
                                    transform: `translate(-50%, -50%) translateZ(${110 + g.height}px) rotateX(-${TILT_DEG}deg) scale(${0.9 - k * 0.1}) rotate(${g.rot}deg)`,
                                }}
                            >
                                <KumpirPotato size={potatoPx} heat={0} />
                            </div>
                        ))}
                        <div className="potatoShadow" style={{ left: flyRender.x, top: flyRender.y + 30, opacity: 0.6 - flyRender.height / 220 }} />
                        <div
                            className="potatoFly"
                            style={{
                                left: flyRender.x,
                                top: flyRender.y - 40,
                                transform: `translate(-50%, -50%) translateZ(${110 + flyRender.height}px) rotateX(-${TILT_DEG}deg) scale(${flyRender.scale}) rotate(${flyRender.t * 540}deg)`,
                            }}
                        >
                            <KumpirPotato size={potatoPx} heat={heat} />
                        </div>
                    </div>
                ) : null}

                {/* Receiver pop highlight */}
                {popPlayerId && popRender ? (
                    <div className="receiverPop" style={{ left: popRender.x, top: popRender.y }} aria-hidden />
                ) : null}
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
        .ringHot .tRim{ filter: brightness(1.12) saturate(1.2); }

        .tableTilt{
          position:absolute;
          inset:0;
          transform-style: preserve-3d;
          transform: rotateX(var(--tilt));
        }

        /* ===== Tisch-Körper (alle Ebenen bei 50% / 27%, gestapelt in Z) ===== */
        .tableBase{
          position:absolute;
          left:50%;
          top:27%;
          transform: translate(-50%,-50%);
          transform-style: preserve-3d;
        }
        .tableBase > *{ position:absolute; inset:0; border-radius:50%; }
        .tShadow{
          transform: translateZ(-70px) scale(1.12);
          background: radial-gradient(circle, rgba(0,0,0,.65) 0%, rgba(0,0,0,.35) 55%, transparent 72%);
          filter: blur(22px);
        }
        /* ===== Plattenteller: Kumpir-Arena als Schallplatte =====
           (statt Pokertisch: dunkles Vinyl, Neon-Ring in den Markenfarben, Label in der Mitte) */
        .tEdge{ background: #0b0c11; }
        .tEdge1{ transform: translateZ(-7px);  background: linear-gradient(180deg, #3a3f52, #1a1d28); }
        .tEdge2{ transform: translateZ(-15px); background: #12141c; }
        .tEdge3{ transform: translateZ(-24px); background: #08090d; box-shadow: 0 0 0 2px rgba(0,0,0,.5), 0 10px 34px rgba(0,0,0,.55); }
        /* Metall-Rand (gebürsteter Stahl) */
        .tRim{
          background:
            radial-gradient(circle at 30% 16%, rgba(255,255,255,.45), transparent 40%),
            repeating-conic-gradient(from 0deg, rgba(255,255,255,.07) 0deg 1deg, rgba(0,0,0,.08) 1deg 2deg),
            conic-gradient(from 30deg, #8d94a8, #dfe4f0 12%, #6d7388 26%, #c3c9da 40%, #565b6f 54%, #d3d8e6 68%, #6d7388 84%, #8d94a8);
          box-shadow: inset 0 0 0 2px rgba(255,255,255,.35), inset 0 -10px 24px rgba(0,0,0,.5), inset 0 6px 12px rgba(255,255,255,.18), 0 0 40px rgba(0,0,0,.5);
        }
        /* Neon-Ring in den Markenfarben (Rot -> Orange -> Gelb) */
        .tNeon{
          inset: 5%;
          transform: translateZ(1px);
          background: conic-gradient(from 90deg, #ff3d2e, #ff7a1a, #ffd23f, #ff7a1a, #ff3d2e, #ff7a1a, #ffd23f, #ff7a1a, #ff3d2e);
          -webkit-mask: radial-gradient(farthest-side, transparent calc(100% - 7px), #000 calc(100% - 6px), #000 calc(100% - 2px), transparent calc(100% - 1px));
          mask: radial-gradient(farthest-side, transparent calc(100% - 7px), #000 calc(100% - 6px), #000 calc(100% - 2px), transparent calc(100% - 1px));
          filter: drop-shadow(0 0 6px rgba(255,140,40,.9));
        }
        /* Vinyl: tiefes Schwarz mit Rillen */
        .tVinyl{
          inset: 7.4%;
          transform: translateZ(2px);
          background:
            radial-gradient(circle at 50% 50%, rgba(255,255,255,.00) 0 30%, rgba(255,255,255,.04) 31% 100%),
            repeating-radial-gradient(circle at 50% 50%, rgba(255,255,255,.045) 0 1px, rgba(0,0,0,.35) 1px 3px),
            radial-gradient(circle at 50% 50%, #20222c 0%, #121319 55%, #07080b 100%);
          box-shadow: inset 0 0 0 2px rgba(0,0,0,.6), inset 0 12px 36px rgba(0,0,0,.5);
        }
        /* Track-Lücken: glatte Ringe wie zwischen den Songs einer Platte */
        .tTracks{
          inset: 7.4%;
          transform: translateZ(2.5px);
          background: radial-gradient(circle,
            transparent 0 46%, rgba(255,255,255,.10) 46.2% 46.9%, transparent 47.1% 63%,
            rgba(255,255,255,.10) 63.2% 63.9%, transparent 64.1% 80%, rgba(255,255,255,.10) 80.2% 80.9%, transparent 81.1%);
        }
        /* Licht-Glanz, der langsam über die Platte wandert */
        .tSheen{
          inset: 7.4%;
          transform: translateZ(3px);
          background: conic-gradient(from 0deg, transparent 0deg 20deg, rgba(255,255,255,.14) 36deg, transparent 56deg 200deg, rgba(255,255,255,.09) 216deg, transparent 236deg 360deg);
          animation: sheenSpin 22s linear infinite;
          -webkit-mask: radial-gradient(circle, transparent 0 14%, #000 15%);
          mask: radial-gradient(circle, transparent 0 14%, #000 15%);
        }
        @keyframes sheenSpin{ from{ transform: translateZ(3px) rotate(0deg); } to{ transform: translateZ(3px) rotate(360deg); } }
        /* Skala-Striche außen */
        .tTicks{
          inset: 9.2%;
          transform: translateZ(3.5px);
          background: repeating-conic-gradient(from -0.6deg, rgba(255,214,120,.5) 0deg 1.2deg, transparent 1.2deg 7.5deg);
          -webkit-mask: radial-gradient(circle, transparent 0 95%, #000 95.5% 100%);
          mask: radial-gradient(circle, transparent 0 95%, #000 95.5% 100%);
        }
        /* Platten-Label in der Mitte */
        .tLabel{
          inset: 37%;
          transform: translateZ(4px);
          background:
            radial-gradient(circle at 34% 28%, rgba(255,255,255,.45), transparent 46%),
            conic-gradient(from 20deg, #ff3d2e, #ff9f1c, #ffd23f, #ff9f1c, #ff3d2e);
          box-shadow: 0 0 0 3px rgba(0,0,0,.65), 0 0 0 4px rgba(255,255,255,.25), 0 4px 14px rgba(0,0,0,.5);
        }
        .tLabel::after{
          content:""; position:absolute; inset: 14%; border-radius: 50%;
          border: 1.5px dashed rgba(60,10,0,.45);
        }
        .tSpindle{
          inset: 48.2%;
          transform: translateZ(5px);
          background: radial-gradient(circle at 35% 30%, #fff, #b7bccb 45%, #4a4f60);
          box-shadow: 0 0 0 2px rgba(0,0,0,.6), 0 2px 4px rgba(0,0,0,.6);
        }
        .tGloss{
          inset: 0;
          transform: translateZ(6px);
          background:
            radial-gradient(ellipse 60% 34% at 34% 16%, rgba(255,255,255,.16), transparent 70%),
            linear-gradient(160deg, rgba(255,255,255,.06), transparent 38%, transparent 70%, rgba(0,0,0,.18));
          pointer-events: none;
        }
        .tPulse{
          inset: -1%;
          transform: translateZ(5px);
          border-radius: 50%;
          pointer-events: none;
          animation: fusePulse var(--pulse, 2.6s) ease-in-out infinite;
        }
        @keyframes fusePulse{
          0%,100%{
            box-shadow: 0 0 calc(10px + 14px * var(--amp, .1)) calc(2px * var(--amp, .1)) rgba(255,90,30, calc(.10 + .25 * var(--amp, .1))),
                        inset 0 0 calc(12px + 20px * var(--amp, .1)) rgba(255,70,20, calc(.05 + .20 * var(--amp, .1)));
          }
          50%{
            box-shadow: 0 0 calc(24px + 56px * var(--amp, .1)) calc(6px + 10px * var(--amp, .1)) rgba(255,70,20, calc(.20 + .65 * var(--amp, .1))),
                        inset 0 0 calc(24px + 50px * var(--amp, .1)) rgba(255,50,10, calc(.12 + .50 * var(--amp, .1)));
          }
        }
        .nextArc{
          position:absolute; inset:0; pointer-events:none;
          transform: translateZ(7px);
          overflow: visible;
        }
        .nextArcPath{
          fill:none;
          stroke: rgba(255,255,255,.4);
          stroke-width: 2.4;
          stroke-linecap: round;
          stroke-dasharray: 7 9;
          animation: arcFlow 1.1s linear infinite;
        }
        @keyframes arcFlow{ to{ stroke-dashoffset: -32; } }

        /* ===== Mitte ===== */
        .tHub{
          position:absolute;
          z-index: 20;
          transform: translate(-50%,-50%) translateZ(18px) rotateX(calc(var(--tilt) * -1)) translateY(-62px);
          text-align:center;
          pointer-events:none;
          display:grid;
          gap:3px;
          justify-items:center;
        }
        .tHubRound{
          font-size: 12px;
          font-weight: 900;
          letter-spacing: 3px;
          color: rgba(255,230,160,.85);
          text-shadow: 0 2px 8px rgba(0,0,0,.6);
        }
        .tHubTempo{
          font-size: 13px;
          font-weight: 900;
          padding: 4px 12px;
          border-radius: 999px;
          background: rgba(0,0,0,.45);
          border: 1px solid rgba(255,214,10,.4);
          color: #ffe08a;
          box-shadow: 0 6px 18px rgba(0,0,0,.4);
        }
        .tHubTempo.duel{
          color: #ffb4a8;
          border-color: rgba(255,90,70,.7);
          background: rgba(120,10,10,.55);
          animation: duelPulse 1.1s ease-in-out infinite;
        }
        @keyframes duelPulse{ 0%,100%{ box-shadow: 0 6px 18px rgba(0,0,0,.4);} 50%{ box-shadow: 0 0 22px rgba(255,70,50,.7);} }

        /* ===== Schatten + Spotlight auf dem Filz ===== */
        .seatShadow{
          position:absolute;
          width: calc(var(--seatH, 64px) + 6px); height: calc(var(--seatH, 64px) + 6px);
          transform: translate(-50%,-50%) translateZ(4px);
          border-radius: 50%;
          background: radial-gradient(circle, rgba(0,0,0,.55) 0%, rgba(0,0,0,.25) 55%, transparent 72%);
          filter: blur(3px);
          transition: left .45s cubic-bezier(.2,1,.2,1), top .45s cubic-bezier(.2,1,.2,1);
        }
        /* Kein mix-blend-mode/filter/opacity auf Kindern der Tischebene: das flacht den 3D-Kontext ab
           und quetscht alle Sitze + Namensschilder zu Ellipsen. */
        .holderSpot{
          position:absolute;
          width: 130px; height: 130px;
          transform: translate(-50%,-50%) translateZ(4px);
          border-radius: 50%;
          background: radial-gradient(circle, rgba(255,160,50,.34) 0%, rgba(255,110,30,.12) 48%, transparent 70%);
          transition: left .5s cubic-bezier(.2,1,.2,1), top .5s cubic-bezier(.2,1,.2,1);
          animation: spotBreath 1.6s ease-in-out infinite;
        }
        @keyframes spotBreath{ 0%,100%{ opacity:.75; } 50%{ opacity:1; } }

        /* ===== Spieler-Sitze (Billboard: stehen aufrecht über dem Tisch) ===== */
        .seat{
          position:absolute;
          width: var(--seat, 54px);
          height: var(--seat, 54px);
          border-radius: 999px;
          transform: translate(-50%, -50%) translateZ(60px) rotateX(calc(var(--tilt) * -1));
          display: grid;
          place-items: center;
          color: #fff;
          font-family: var(--font-display);
          font-weight: 800;
          font-size: 16px;
          letter-spacing: .3px;
          z-index: 30;
          opacity: .94;
          /* Metall-Ring in der Spielerfarbe */
          background: conic-gradient(from 200deg,
            hsl(var(--h) 80% 86%), hsl(var(--h) 62% 48%) 18%, hsl(var(--h) 85% 82%) 36%,
            hsl(var(--h) 60% 36%) 58%, hsl(var(--h) 80% 80%) 78%, hsl(var(--h) 80% 86%));
          box-shadow: 0 12px 24px rgba(0,0,0,.5), 0 2px 0 rgba(0,0,0,.35), inset 0 1px 1px rgba(255,255,255,.7);
          transition: left .45s cubic-bezier(.2,1,.2,1), top .45s cubic-bezier(.2,1,.2,1), transform .25s cubic-bezier(.2,1,.2,1), box-shadow .25s ease, opacity .25s ease;
        }
        .seatFace{
          position:absolute; inset: 11%; border-radius: 50%;
          background: radial-gradient(circle at 34% 26%, hsl(var(--h) 88% 74%), hsl(calc(var(--h) + 20) 74% 46%) 58%, hsl(calc(var(--h) + 36) 70% 26%));
          box-shadow: inset 0 3px 5px rgba(255,255,255,.38), inset 0 -7px 12px rgba(0,0,0,.45), 0 0 0 1px rgba(0,0,0,.35);
        }
        .seatGloss{
          position:absolute; top: 9%; left: 20%; width: 50%; height: 32%; border-radius: 50%;
          background: linear-gradient(180deg, rgba(255,255,255,.7), rgba(255,255,255,0));
          pointer-events: none;
        }
        .seatInitials{ position: relative; text-shadow: 0 2px 6px rgba(0,0,0,.6); user-select:none; }
        .nameTag{
          position:absolute;
          z-index: 35;
          transform: translate(var(--tx, -50%), var(--ty, 0%)) translateZ(24px) rotateX(calc(var(--tilt) * -1));
          display:flex; align-items:center; gap:6px;
          max-width: var(--tagMax, 210px);
          padding: 5px 12px;
          border-radius: 999px;
          background: rgba(8,12,24,.82);
          border: 1px solid rgba(255,255,255,.28);
          box-shadow: 0 6px 16px rgba(0,0,0,.45);
          color: #fff;
          font-size: var(--tagFs, 15px);
          font-weight: 900;
          letter-spacing: .2px;
          white-space: nowrap;
          transition: left .45s cubic-bezier(.2,1,.2,1), top .45s cubic-bezier(.2,1,.2,1), border-color .25s ease, background .25s ease;
        }
        .nameTagText{ overflow:hidden; text-overflow: ellipsis; min-width: 0; }
        .ringNarrow .nameTag{ white-space: nowrap; padding: 3px 8px; gap: 4px; }
        .ringNarrow .nameTagMe{ display: none; }
        .ringNarrow .nameTagPts{ font-size: 10px; }
        .nameTagMe{
          flex: none; font-size: 11px; font-weight: 900; padding: 1px 7px; border-radius: 999px;
          background: rgba(34,211,238,.22); border: 1px solid rgba(34,211,238,.7); color: #b9f4ff;
        }
        .nameTagPts{ flex: none; font-size: 12px; font-weight: 900; color: #ffe08a; }
        .nameTag.me{ border-color: rgba(34,211,238,.85); }
        .nameTag.holder{ background: rgba(122,64,0,.92); border-color: rgba(255,214,10,.9); color: #fff3c4; }
        .nameTag.gone{ opacity: 0; }
        .seat.me{
          background: conic-gradient(from 200deg, #d9fbff, #19b5d4 20%, #e8fdff 38%, #0e7f9a 60%, #c9f6ff 80%, #d9fbff);
          box-shadow: 0 12px 26px rgba(0,0,0,.5), 0 0 0 4px rgba(34,211,238,.28), 0 0 22px rgba(34,211,238,.35), inset 0 1px 1px rgba(255,255,255,.8);
          opacity: 1;
        }
        .seat.holder{
          width: var(--seatH, 64px);
          height: var(--seatH, 64px);
          opacity: 1;
          font-size: 19px;
          transform: translate(-50%, -50%) translateZ(76px) rotateX(calc(var(--tilt) * -1)) scale(1.12);
          background: conic-gradient(from 200deg, #fff6c8, #ffc21a 18%, #fff0a8 36%, #c27a00 58%, #ffe27a 78%, #fff6c8);
          box-shadow:
            0 18px 36px rgba(0,0,0,.55),
            0 0 0 5px rgba(255,149,0,.30),
            0 0 40px rgba(255,120,30,.7),
            inset 0 1px 1px rgba(255,255,255,.9);
          animation: seatHolderPulse 1.3s ease-in-out infinite;
        }
        .seat.dead{ opacity:.34; filter: grayscale(.9); }
        .seatDeadOverlay{
          position:absolute; inset:0; display:grid; place-items:center;
          font-size: 24px; background: rgba(0,0,0,.34); border-radius: 999px;
        }
        .seatBoom{
          position:absolute; inset:-34px; display:grid; place-items:center; pointer-events:none;
        }
        .boomFlash{
          position:absolute; inset: 6px; border-radius: 50%;
          background: radial-gradient(circle, #fffbe0 0%, #ffd23f 28%, #ff7a1a 55%, rgba(255,60,0,0) 72%);
          animation: boomFlash 720ms cubic-bezier(.2,.9,.2,1) both;
        }
        .boomRing{
          position:absolute; inset: 14px; border-radius: 50%;
          border: 4px solid rgba(255,214,120,.9);
          animation: boomRing 720ms cubic-bezier(.2,.9,.2,1) both;
        }
        .boomEmoji{ position: relative; font-size: 54px; animation: seatBoom 700ms cubic-bezier(.2,1,.2,1) both; }
        @keyframes boomFlash{ 0%{ opacity:0; transform: scale(.3); } 25%{ opacity:1; transform: scale(1.1); } 100%{ opacity:0; transform: scale(1.8); } }
        @keyframes boomRing{ 0%{ opacity:.95; transform: scale(.4); } 100%{ opacity:0; transform: scale(2.3); } }
        .seat.exploded{ animation: seatShake 700ms cubic-bezier(.36,.07,.19,.97) both; }
        .seatStale{
          position:absolute; bottom:-8px; left:-8px;
          background: rgba(120,20,20,.78); border: 1px solid rgba(255,255,255,.24);
          border-radius: 999px; padding: 2px 5px; font-size: 12px; line-height:1;
          animation: staleBlink 1.6s ease-in-out infinite;
        }
        @keyframes staleBlink{ 0%,100%{opacity:1;} 50%{opacity:.45;} }
        @keyframes seatHolderPulse{
          0%,100%{ box-shadow: 0 16px 34px rgba(0,0,0,.55), 0 0 0 5px rgba(255,149,0,.24), 0 0 30px rgba(255,110,30,.5), inset 0 3px 6px rgba(255,255,255,.35); }
          50%{ box-shadow: 0 20px 40px rgba(0,0,0,.6), 0 0 0 7px rgba(255,149,0,.38), 0 0 54px rgba(255,110,30,.85), inset 0 3px 6px rgba(255,255,255,.35); }
        }
        @keyframes seatBoom{
          0%{ opacity:0; transform: scale(.5); }
          40%{ opacity:1; transform: scale(1.4); }
          100%{ opacity:0; transform: scale(1.9); }
        }
        @keyframes seatShake{
          0%,100%{ translate: 0 0; }
          20%{ translate: -6px -4px; }
          40%{ translate: 6px 3px; }
          60%{ translate: -4px 5px; }
          80%{ translate: 4px -4px; }
        }

        /* ===== Kumpir ===== */
        .potatoShadow{
          position:absolute;
          width: 46px; height: 46px;
          transform: translate(-50%,-50%) translateZ(5px) scaleY(.7);
          border-radius:50%;
          background: radial-gradient(circle, rgba(0,0,0,.6), transparent 70%);
          filter: blur(2px);
          transition: left .5s cubic-bezier(.2,1,.2,1), top .5s cubic-bezier(.2,1,.2,1);
        }
        .tablePotato{
          position:absolute;
          z-index: 40;
          width: var(--potatoPx, 52px);
          height: var(--potatoPx, 52px);
          line-height: 0;
          transform: translate(-50%, -50%) translateZ(106px) rotateX(calc(var(--tilt) * -1));
          filter: drop-shadow(0 10px 14px rgba(0,0,0,.55)) drop-shadow(0 0 16px rgba(255,150,40,.6));
          transition: left .5s cubic-bezier(.2,1,.2,1), top .5s cubic-bezier(.2,1,.2,1);
          animation: potatoBob 1.2s ease-in-out infinite;
        }
        .potatoFly, .potatoGhost{
          position:absolute;
          width: var(--potatoPx, 52px);
          height: var(--potatoPx, 52px);
          line-height: 0;
        }
        .potatoFly{ filter: drop-shadow(0 12px 16px rgba(0,0,0,.55)) drop-shadow(0 0 20px rgba(255,170,50,.85)); }
        .potatoGhost{ pointer-events:none; }
        @keyframes potatoBob{
          0%,100%{ margin-top: 0; }
          50%{ margin-top: -7px; }
        }

        .passOverlay{ position:absolute; inset:0; pointer-events:none; z-index: 50; transform-style: preserve-3d; }
        .trailSvg{ position:absolute; inset:0; transform: translateZ(6px); }
        .trailPath{
          fill:none;
          stroke: rgba(255,214,120,.6);
          stroke-width: 3.5;
          stroke-linecap: round;
          stroke-dasharray: 220;
          filter: drop-shadow(0 0 8px rgba(255,170,50,.8));
          transition: stroke-dashoffset 80ms linear;
        }

        .receiverPop{
          position:absolute;
          width: 120px; height: 120px;
          border-radius: 999px;
          background: radial-gradient(circle, rgba(255,214,10,.4), rgba(255,45,85,.16), transparent 70%);
          filter: blur(8px);
          animation: pop 420ms cubic-bezier(.2,1,.2,1) both;
          z-index: 40;
          transform: translate(-50%,-50%) translateZ(6px);
        }
        @keyframes pop{
          0%{ opacity:0; scale:.6; }
          50%{ opacity:1; scale:1.1; }
          100%{ opacity:0; scale:.9; }
        }

        @media (prefers-reduced-motion: reduce){
          .tablePotato, .holderSpot, .seat.holder, .tHubTempo.duel, .tPulse, .nextArcPath{ animation: none; }
        }
      `}</style>
        </div>
    );
}
