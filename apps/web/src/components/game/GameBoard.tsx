"use client";

import { useEffect, useMemo } from "react";
import { PassButton } from "./PassButton";

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

type Props = {
    holderPlayerId: string | null;
    players: Player[];
    mePlayerId: string | null;
    onPass: () => Promise<unknown> | void;
};

export function GameBoard({ holderPlayerId, players, mePlayerId, onPass }: Props) {
    const isMeHolder = !!mePlayerId && mePlayerId === holderPlayerId;

    const holderName = useMemo(() => {
        if (!holderPlayerId) return "…";
        return players.find((p) => p.player_id === holderPlayerId)?.name ?? "…";
    }, [players, holderPlayerId]);

    // Spacebar to pass (only if you are holder)
    useEffect(() => {
        function onKeyDown(e: KeyboardEvent) {
            if (e.code !== "Space") return;

            // avoid scrolling on Space
            e.preventDefault();

            if (!isMeHolder) return;
            onPass();
        }

        window.addEventListener("keydown", onKeyDown, { passive: false });
        return () => window.removeEventListener("keydown", onKeyDown);
    }, [isMeHolder, onPass]);

    return (
        <main style={styles.screen(isMeHolder)}>
            {/* Hot / Calm atmospheric layers */}
            {isMeHolder ? <HotEdges /> : <CalmAtmos />}

            {/* Center content */}
            <div style={styles.center}>
                <div style={styles.label(isMeHolder)}>
                    {isMeHolder ? "DU HAST DIE KARTOFFEL" : "AKTUELLER HOLDER"}
                </div>

                <div style={styles.name(isMeHolder)}>
                    {holderName}
                </div>

                <div style={styles.hint(isMeHolder)}>
                    {isMeHolder ? "Leertaste oder Button drücken." : "Warte…"}
                </div>

                <div style={{ marginTop: 18 }}>
                    <PassButton disabled={!isMeHolder} onClick={onPass} />
                </div>
            </div>

            <style jsx global>{`
                @keyframes flameFlicker {
                    0%   { opacity: 0.55; transform: translateY(0px) scale(1); }
                    50%  { opacity: 0.95; transform: translateY(-2px) scale(1.01); }
                    100% { opacity: 0.55; transform: translateY(0px) scale(1); }
                }
                @keyframes slowDrift {
                    0%   { transform: translateY(0px); opacity: 0.55; }
                    50%  { transform: translateY(-6px); opacity: 0.75; }
                    100% { transform: translateY(0px); opacity: 0.55; }
                }
            `}</style>
        </main>
    );
}

/** Holder: flames around screen edges */
function HotEdges() {
    return (
        <>
            {/* warm base glow */}
            <div
                aria-hidden
                style={{
                    position: "absolute",
                    inset: 0,
                    pointerEvents: "none",
                    background:
                        "radial-gradient(900px 520px at 50% 40%, rgba(255,120,40,0.32), transparent 62%), radial-gradient(1100px 620px at 50% 75%, rgba(255,50,60,0.14), transparent 70%)",
                    filter: "blur(10px)",
                    opacity: 0.95,
                }}
            />

            {/* top flame edge */}
            <div aria-hidden style={styles.flameEdge("top")} />
            {/* bottom flame edge */}
            <div aria-hidden style={styles.flameEdge("bottom")} />
            {/* left flame edge */}
            <div aria-hidden style={styles.flameEdge("left")} />
            {/* right flame edge */}
            <div aria-hidden style={styles.flameEdge("right")} />

            {/* subtle vignette so center stays readable */}
            <div
                aria-hidden
                style={{
                    position: "absolute",
                    inset: 0,
                    pointerEvents: "none",
                    background:
                        "radial-gradient(circle at 50% 45%, rgba(0,0,0,0.0) 0%, rgba(0,0,0,0.18) 58%, rgba(0,0,0,0.32) 86%)",
                }}
            />
        </>
    );
}

/** Non-holder: calm ambient background */
function CalmAtmos() {
    return (
        <>
            <div
                aria-hidden
                style={{
                    position: "absolute",
                    inset: 0,
                    pointerEvents: "none",
                    background:
                        "radial-gradient(900px 520px at 50% 35%, rgba(255,255,255,0.10), transparent 62%), radial-gradient(1100px 700px at 50% 80%, rgba(0,0,0,0.18), transparent 70%)",
                    filter: "blur(10px)",
                    opacity: 0.9,
                    animation: "slowDrift 6.5s ease-in-out infinite",
                }}
            />
            <div
                aria-hidden
                style={{
                    position: "absolute",
                    inset: 0,
                    pointerEvents: "none",
                    background:
                        "radial-gradient(circle at 50% 45%, rgba(0,0,0,0.0) 0%, rgba(0,0,0,0.18) 60%, rgba(0,0,0,0.28) 88%)",
                }}
            />
        </>
    );
}

const styles = {
    screen: (hot: boolean): React.CSSProperties => ({
        position: "relative",
        minHeight: "100vh",
        width: "100vw",
        overflow: "hidden",
        display: "grid",
        placeItems: "center",
        padding: 24,
        background: hot
            ? "radial-gradient(circle at 50% 35%, rgba(255,140,70,0.55) 0%, rgba(143,15,15,0.96) 72%)"
            : "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(243,168,59,0.55) 0%, rgba(192,106,0,0.88) 80%)",
        transition: "background 350ms ease",
    }),
    center: {
        position: "relative",
        zIndex: 5,
        textAlign: "center",
        width: "min(920px, 96vw)",
        padding: "0 14px",
    } as React.CSSProperties,
    label: (hot: boolean): React.CSSProperties => ({
        fontSize: 13,
        fontWeight: 900,
        letterSpacing: 1.6,
        opacity: 0.75,
        textTransform: "uppercase",
        marginBottom: 14,
        color: hot ? "rgba(255,235,220,0.92)" : "rgba(255,255,255,0.82)",
    }),
    name: (hot: boolean): React.CSSProperties => ({
        fontSize: "clamp(44px, 6vw, 82px)",
        fontWeight: 950,
        letterSpacing: 0.6,
        lineHeight: 1.05,
        textShadow: hot
            ? "0 0 38px rgba(255,90,40,0.70), 0 0 120px rgba(255,60,60,0.20)"
            : "0 14px 70px rgba(0,0,0,0.28)",
    }),
    hint: (hot: boolean): React.CSSProperties => ({
        marginTop: 12,
        fontSize: 14,
        fontWeight: 700,
        opacity: 0.72,
        color: hot ? "rgba(255,235,220,0.85)" : "rgba(255,255,255,0.75)",
    }),

    flameEdge: (side: "top" | "bottom" | "left" | "right"): React.CSSProperties => {
        const common: React.CSSProperties = {
            position: "absolute",
            pointerEvents: "none",
            zIndex: 2,
            animation: "flameFlicker 1.15s ease-in-out infinite",
            filter: "blur(10px)",
            opacity: 0.85,
            mixBlendMode: "screen",
        };

        // Flame gradient “sheet” that hugs an edge
        if (side === "top") {
            return {
                ...common,
                left: -40,
                right: -40,
                top: -40,
                height: 160,
                background:
                    "radial-gradient(120px 90px at 10% 80%, rgba(255,90,40,0.55), transparent 60%)," +
                    "radial-gradient(140px 100px at 35% 75%, rgba(255,160,70,0.45), transparent 62%)," +
                    "radial-gradient(160px 110px at 60% 80%, rgba(255,70,60,0.45), transparent 62%)," +
                    "radial-gradient(140px 100px at 85% 78%, rgba(255,190,90,0.35), transparent 62%)",
            };
        }
        if (side === "bottom") {
            return {
                ...common,
                left: -40,
                right: -40,
                bottom: -40,
                height: 160,
                background:
                    "radial-gradient(140px 100px at 15% 20%, rgba(255,90,40,0.50), transparent 62%)," +
                    "radial-gradient(170px 120px at 45% 25%, rgba(255,150,70,0.42), transparent 62%)," +
                    "radial-gradient(160px 110px at 70% 20%, rgba(255,70,60,0.42), transparent 62%)," +
                    "radial-gradient(140px 100px at 90% 22%, rgba(255,190,90,0.32), transparent 62%)",
            };
        }
        if (side === "left") {
            return {
                ...common,
                top: -40,
                bottom: -40,
                left: -40,
                width: 160,
                background:
                    "radial-gradient(120px 90px at 80% 15%, rgba(255,90,40,0.40), transparent 62%)," +
                    "radial-gradient(140px 100px at 78% 45%, rgba(255,160,70,0.32), transparent 62%)," +
                    "radial-gradient(150px 110px at 82% 75%, rgba(255,70,60,0.32), transparent 62%)",
            };
        }
        // right
        return {
            ...common,
            top: -40,
            bottom: -40,
            right: -40,
            width: 160,
            background:
                "radial-gradient(120px 90px at 20% 15%, rgba(255,90,40,0.40), transparent 62%)," +
                "radial-gradient(140px 100px at 22% 45%, rgba(255,160,70,0.32), transparent 62%)," +
                "radial-gradient(150px 110px at 18% 75%, rgba(255,70,60,0.32), transparent 62%)",
        };
    },
};