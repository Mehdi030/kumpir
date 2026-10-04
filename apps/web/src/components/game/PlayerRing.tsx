"use client";

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
};

const TILT_DEG = 52;
const FUSE_R = 46.5;
const FUSE_LEN = 2 * Math.PI * FUSE_R;

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
}: Props) {
    const isDisconnected = useCallback(
        (id: string) => (disconnectedIds instanceof Set ? disconnectedIds.has(id) : (disconnectedIds ?? []).includes(id)),
        [disconnectedIds]
    );

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

        const startAngle = -Math.PI / 2;
        const step = (Math.PI * 2) / n;

        for (let i = 0; i < n; i++) {
            const a = startAngle + i * step;
            map.set(seatedPlayers[i]!.player_id, { x: Math.cos(a), y: Math.sin(a) });
        }
        return map;
    }, [seatedPlayers]);

    // Convert relative coords to px coords using state-tracked size (no ref reads during render)
    const getPx = useCallback(
        (id: string): Pt | null => {
            const rel = positions.get(id);
            if (!rel) return null;
            if (size.w <= 0 || size.h <= 0) return null;

            const minSide = Math.min(size.w, size.h);
            const cx = size.w / 2;
            // Oberhalb der Antwort-Box (.hud) statt exakt Bildschirmmitte.
            const cy = size.h * 0.27;
            // Sitze auf der Filzplatte knapp innerhalb des Holzrands.
            const r = Math.min(minSide * 0.235, 195);

            return { x: cx + rel.x * r, y: cy + rel.y * r };
        },
        [positions, size.w, size.h]
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

    const popRender = useMemo(() => {
        if (!popPlayerId) return null;
        return getPx(popPlayerId);
    }, [popPlayerId, getPx]);

    // Zündschnur: Anteil, der noch NICHT abgebrannt ist.
    const remaining = Math.max(0, Math.min(1, 1 - heat));
    const fuseHue = Math.round(52 - 52 * Math.max(0, Math.min(1, heat)));
    const fuseColor = `hsl(${fuseHue} 100% 56%)`;
    const sparkAngle = -Math.PI / 2 + 2 * Math.PI * remaining;
    const sparkX = 50 + FUSE_R * Math.cos(sparkAngle);
    const sparkY = 50 + FUSE_R * Math.sin(sparkAngle);
    const hot = heat > 0.66;

    return (
        <div ref={containerRef} className={`ringWrap ${hot ? "ringHot" : ""}`} style={{ ["--tilt" as string]: `${TILT_DEG}deg` }}>
            <div className="tableTilt">
                {/* ---------- Tisch ---------- */}
                <div className="tableBase" aria-hidden>
                    <div className="tShadow" />
                    <div className="tEdge tEdge3" />
                    <div className="tEdge tEdge2" />
                    <div className="tEdge tEdge1" />
                    <div className="tRim" />
                    <div className="tFelt" />
                    <div className="tGoldRing" />

                    {/* Zündschnur rund um den Rand: brennt von oben im Uhrzeigersinn ab. */}
                    <svg className="tFuse" viewBox="0 0 100 100">
                        <circle className="fuseTrack" cx="50" cy="50" r={FUSE_R} />
                        <circle
                            className="fuseBurn"
                            cx="50"
                            cy="50"
                            r={FUSE_R}
                            transform="rotate(-90 50 50)"
                            strokeDasharray={`${(FUSE_LEN * remaining).toFixed(2)} ${FUSE_LEN.toFixed(2)}`}
                            style={{ stroke: fuseColor }}
                        />
                        {remaining > 0.005 && remaining < 0.995 ? (
                            <>
                                <circle className="fuseSparkGlow" cx={sparkX} cy={sparkY} r="4.2" />
                                <circle className="fuseSpark" cx={sparkX} cy={sparkY} r="1.9" />
                            </>
                        ) : null}
                    </svg>
                </div>

                {/* Tisch-Mitte: Runde + Tempo, aufrecht gestellt (Billboard). */}
                {size.w > 0 ? (
                    <div className="tHub" style={{ left: size.w / 2, top: size.h * 0.27 }}>
                        <div className="tHubRound">RUNDE {round}</div>
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
                    const pts = p.song_points ?? 0;

                    return (
                        <div
                            key={p.player_id}
                            className={`seat ${isHolder ? "holder" : ""} ${isMe ? "me" : ""} ${!p.is_alive ? "dead" : ""} ${isExploded ? "exploded" : ""}`}
                            style={{
                                left: pos.x,
                                top: pos.y,
                                background: `radial-gradient(circle at 32% 26%, hsl(${hue},90%,74%), hsl(${(hue + 24) % 360},78%,46%) 62%, hsl(${(hue + 40) % 360},70%,30%))`,
                            }}
                            aria-label={p.name}
                            title={p.name}
                        >
                            <span className="seatInitials">{initialsFor(p.name)}</span>
                            <span className="seatName">
                                {p.name}
                                {isMe ? " (du)" : ""}
                            </span>
                            {pts > 0 ? <span className="seatPts">♪ {fmtPts(pts)}</span> : null}
                            {!p.is_alive ? <span className="seatDeadOverlay" aria-hidden>💀</span> : null}
                            {isExploded ? <span className="seatBoom" aria-hidden>💥</span> : null}
                            {isStale ? (
                                <span className="seatStale" title="Verbindung verloren?" aria-label="Verbindung verloren?">
                                    📡
                                </span>
                            ) : null}
                        </div>
                    );
                })}

                {/* Kumpir liegt beim aktuellen Halter, schwebt leicht und gleitet
                    beim Wechsel zum nächsten Platz; nur während der Wurf-
                    Animation wird sie ausgeblendet. */}
                {holderPos && !flyRender ? (
                    <>
                        <div className="potatoShadow" style={{ left: holderPos.x, top: holderPos.y + 30 }} aria-hidden />
                        <div className="tablePotato" style={{ left: holderPos.x, top: holderPos.y - 40 }} aria-hidden>
                            🥔
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
                        <div className="potatoShadow" style={{ left: flyRender.x, top: flyRender.y + 30, opacity: 0.6 - flyRender.height / 220 }} />
                        <div
                            className="potatoFly"
                            style={{
                                left: flyRender.x,
                                top: flyRender.y - 40,
                                transform: `translate(-50%, -50%) translateZ(${110 + flyRender.height}px) rotateX(-${TILT_DEG}deg) scale(${flyRender.scale}) rotate(${flyRender.t * 540}deg)`,
                            }}
                        >
                            🥔
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
          width: min(58vmin, 500px);
          height: min(58vmin, 500px);
          transform: translate(-50%,-50%);
          transform-style: preserve-3d;
        }
        .tableBase > *{ position:absolute; inset:0; border-radius:50%; }
        .tShadow{
          transform: translateZ(-70px) scale(1.12);
          background: radial-gradient(circle, rgba(0,0,0,.65) 0%, rgba(0,0,0,.35) 55%, transparent 72%);
          filter: blur(22px);
        }
        .tEdge{ background: #1c0f06; }
        .tEdge1{ transform: translateZ(-7px);  background: #3a2110; }
        .tEdge2{ transform: translateZ(-15px); background: #2a170a; }
        .tEdge3{ transform: translateZ(-24px); background: #1a0d05; box-shadow: 0 0 0 2px rgba(0,0,0,.4); }
        .tRim{
          background:
            conic-gradient(from 20deg, #8a5a2c, #b98245 12%, #6e431d 25%, #a8733a 40%, #5c3718 55%, #b07a3e 70%, #6e431d 85%, #8a5a2c);
          box-shadow: inset 0 0 0 2px rgba(255,220,170,.28), inset 0 -10px 26px rgba(0,0,0,.45), 0 0 40px rgba(0,0,0,.4);
        }
        .tFelt{
          inset: 7.5%;
          transform: translateZ(2px);
          background:
            radial-gradient(circle at 36% 28%, rgba(255,255,255,.16), transparent 46%),
            repeating-radial-gradient(circle at 50% 50%, rgba(255,255,255,.025) 0 2px, transparent 2px 6px),
            radial-gradient(circle at 50% 50%, #1f7a55 0%, #146141 52%, #0b3d2a 100%);
          box-shadow: inset 0 0 0 3px rgba(0,0,0,.45), inset 0 14px 40px rgba(0,0,0,.55), inset 0 0 70px rgba(0,0,0,.35);
        }
        .tGoldRing{
          inset: 24%;
          transform: translateZ(3px);
          border: 2px solid rgba(255,214,10,.32);
          box-shadow: 0 0 18px rgba(255,214,10,.14), inset 0 0 18px rgba(255,214,10,.08);
        }
        .tFuse{
          inset: 0;
          width: 100%;
          height: 100%;
          transform: translateZ(5px);
          overflow: visible;
        }
        .fuseTrack{
          fill: none;
          stroke: rgba(0,0,0,.45);
          stroke-width: 2.6;
        }
        .fuseBurn{
          fill: none;
          stroke-width: 2.6;
          stroke-linecap: round;
          filter: drop-shadow(0 0 3px currentColor);
          transition: stroke-dasharray .24s linear, stroke .3s ease;
        }
        .fuseSparkGlow{ fill: rgba(255,200,60,.38); animation: sparkFlicker .16s steps(2) infinite; }
        .fuseSpark{ fill: #fff7d6; animation: sparkFlicker .16s steps(2) infinite reverse; }
        @keyframes sparkFlicker{ 0%{ opacity:1; } 100%{ opacity:.55; } }

        /* ===== Mitte ===== */
        .tHub{
          position:absolute;
          z-index: 20;
          transform: translate(-50%,-50%) translateZ(18px) rotateX(calc(var(--tilt) * -1));
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
          width: 64px; height: 64px;
          transform: translate(-50%,-50%) translateZ(4px);
          border-radius: 50%;
          background: radial-gradient(circle, rgba(0,0,0,.55) 0%, rgba(0,0,0,.25) 55%, transparent 72%);
          filter: blur(3px);
          transition: left .45s cubic-bezier(.2,1,.2,1), top .45s cubic-bezier(.2,1,.2,1);
        }
        .holderSpot{
          position:absolute;
          width: 170px; height: 170px;
          transform: translate(-50%,-50%) translateZ(4px);
          border-radius: 50%;
          background: radial-gradient(circle, rgba(255,190,70,.55) 0%, rgba(255,120,30,.22) 45%, transparent 70%);
          mix-blend-mode: screen;
          transition: left .5s cubic-bezier(.2,1,.2,1), top .5s cubic-bezier(.2,1,.2,1);
          animation: spotBreath 1.6s ease-in-out infinite;
        }
        @keyframes spotBreath{ 0%,100%{ opacity:.75; } 50%{ opacity:1; } }

        /* ===== Spieler-Sitze (Billboard: stehen aufrecht über dem Tisch) ===== */
        .seat{
          position:absolute;
          width: 50px;
          height: 50px;
          border-radius: 999px;
          transform: translate(-50%, -50%) translateZ(60px) rotateX(calc(var(--tilt) * -1));
          display: grid;
          place-items: center;
          color: rgba(255,255,255,.96);
          font-weight: 900;
          font-size: 15px;
          letter-spacing: .4px;
          border: 3px solid rgba(255,255,255,.55);
          box-shadow: 0 10px 22px rgba(0,0,0,.45), inset 0 -6px 12px rgba(0,0,0,.35), inset 0 3px 6px rgba(255,255,255,.28);
          z-index: 30;
          opacity: .92;
          transition: left .45s cubic-bezier(.2,1,.2,1), top .45s cubic-bezier(.2,1,.2,1), transform .25s cubic-bezier(.2,1,.2,1), box-shadow .25s ease, border-color .25s ease, opacity .25s ease;
        }
        .seatInitials{ text-shadow: 0 2px 8px rgba(0,0,0,.55); user-select:none; }
        .seat .seatName{
          position:absolute;
          top: calc(100% + 6px);
          left: 50%;
          transform: translateX(-50%);
          font-size: 11px;
          font-weight: 900;
          padding: 2px 9px;
          border-radius: 999px;
          background: rgba(10,10,14,.72);
          border: 1px solid rgba(255,255,255,.14);
          white-space: nowrap;
          max-width: 110px;
          overflow:hidden;
          text-overflow: ellipsis;
          box-shadow: 0 4px 10px rgba(0,0,0,.35);
        }
        .seat .seatPts{
          position:absolute;
          top: calc(100% + 28px);
          left: 50%;
          transform: translateX(-50%);
          font-size: 10px;
          font-weight: 900;
          color: #ffe08a;
          text-shadow: 0 1px 4px rgba(0,0,0,.7);
          white-space: nowrap;
        }
        .seat.me{
          border-color: rgba(34,211,238,.95);
          box-shadow: 0 10px 26px rgba(0,0,0,.5), 0 0 0 4px rgba(34,211,238,.22), inset 0 3px 6px rgba(255,255,255,.28);
          opacity: 1;
        }
        .seat.me .seatName{ border-color: rgba(34,211,238,.6); }
        .seat.holder{
          width: 60px;
          height: 60px;
          opacity: 1;
          font-size: 17px;
          transform: translate(-50%, -50%) translateZ(76px) rotateX(calc(var(--tilt) * -1)) scale(1.12);
          border-color: #ffd60a;
          box-shadow:
            0 16px 34px rgba(0,0,0,.55),
            0 0 0 5px rgba(255,149,0,.28),
            0 0 38px rgba(255,110,30,.65),
            inset 0 3px 6px rgba(255,255,255,.35);
          animation: seatHolderPulse 1.3s ease-in-out infinite;
        }
        .seat.holder .seatName{ background: rgba(120,60,0,.85); border-color: rgba(255,214,10,.7); color:#fff3c4; }
        .seat.dead{ opacity:.34; filter: grayscale(.9); }
        .seatDeadOverlay{
          position:absolute; inset:0; display:grid; place-items:center;
          font-size: 24px; background: rgba(0,0,0,.34); border-radius: 999px;
        }
        .seatBoom{
          position:absolute; inset:-22px; display:grid; place-items:center;
          font-size: 64px; pointer-events:none;
          animation: seatBoom 700ms cubic-bezier(.2,1,.2,1) both;
        }
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
          font-size: 40px;
          line-height: 1;
          transform: translate(-50%, -50%) translateZ(132px) rotateX(calc(var(--tilt) * -1));
          filter: drop-shadow(0 10px 16px rgba(0,0,0,.55)) drop-shadow(0 0 14px rgba(255,150,40,.55));
          transition: left .5s cubic-bezier(.2,1,.2,1), top .5s cubic-bezier(.2,1,.2,1);
          animation: potatoBob 1.2s ease-in-out infinite;
        }
        .potatoFly{
          position:absolute;
          font-size: 40px;
          line-height:1;
          filter: drop-shadow(0 10px 16px rgba(0,0,0,.55)) drop-shadow(0 0 18px rgba(255,170,50,.8));
        }
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
          .tablePotato, .holderSpot, .seat.holder, .tHubTempo.duel, .fuseSparkGlow, .fuseSpark{ animation: none; }
        }
      `}</style>
        </div>
    );
}
