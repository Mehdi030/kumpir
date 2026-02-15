"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

import { GameBoard } from "@/components/game/GameBoard";
import { passPotato } from "@/actions/passPotato";
import { tickGame } from "@/actions/tickGame";
import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";

type LobbyPhase = "lobby" | "running" | "round_end" | "finished" | string;

type LobbyState = {
    id: string;
    holder_player_id: string | null;
    phase: LobbyPhase;
    last_activity_at: string | null; // ✅ used as server-anchored start timestamp
};

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

type IntroStage = "countdown" | "reveal" | "done";

function goLobby(code: string) {
    if (typeof window === "undefined") return;
    window.location.replace(`/lobby/${code}`);
}

export default function GamePage() {
    const supabase = getSupabaseClient();
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId } = usePlayerIdentity();

    const [lobby, setLobby] = useState<LobbyState | null>(null);
    const [players, setPlayers] = useState<Player[]>([]);
    const [fatalError, setFatalError] = useState<string>("");

    const inFlightRef = useRef(false);

    // Intro flow
    const [showIntro, setShowIntro] = useState(false);
    const [introStage, setIntroStage] = useState<IntroStage>("countdown");
    const [countdown, setCountdown] = useState(5);

    // server-anchored start time (ms)
    const [runStartedAtMs, setRunStartedAtMs] = useState<number | null>(null);

    // Guard: only start intro once per running session
    const introStartedForRunRef = useRef(false);

    const meRow = useMemo(() => {
        if (!mePlayerId) return null;
        return players.find((p) => p.player_id === mePlayerId) ?? null;
    }, [players, mePlayerId]);

    const iAmEliminated = !!meRow && !meRow.is_alive;

    const isMeHolder = useMemo(() => {
        if (!mePlayerId || !lobby?.holder_player_id) return false;
        return lobby.holder_player_id === mePlayerId;
    }, [lobby?.holder_player_id, mePlayerId]);

    const holderName = useMemo(() => {
        if (!lobby?.holder_player_id) return "…";
        return players.find((p) => p.player_id === lobby.holder_player_id)?.name ?? "…";
    }, [players, lobby?.holder_player_id]);

    useEffect(() => {
        let alive = true;

        async function load() {
            if (inFlightRef.current) return;
            inFlightRef.current = true;

            try {
                // Best-effort tick (ignore failures)
                try {
                    await tickGame(code);
                } catch {
                    // ignore
                }

                const lobbyRes = await supabase
                    .from("lobbies")
                    .select("id, holder_player_id, phase, last_activity_at")
                    .eq("code", code)
                    .single();

                if (!alive) return;

                if (lobbyRes.error || !lobbyRes.data) {
                    setFatalError(lobbyRes.error?.message ?? "Lobby konnte nicht geladen werden.");
                    return;
                }

                const nextLobby: LobbyState = {
                    id: lobbyRes.data.id,
                    holder_player_id: lobbyRes.data.holder_player_id,
                    phase: lobbyRes.data.phase,
                    last_activity_at: lobbyRes.data.last_activity_at ?? null,
                };

                setLobby(nextLobby);

                // ✅ capture server start timestamp (last_activity_at is set on startGame)
                if (nextLobby.phase === "running" && nextLobby.last_activity_at) {
                    const ms = Date.parse(nextLobby.last_activity_at);
                    if (!Number.isNaN(ms)) setRunStartedAtMs(ms);
                }

                const playersRes = await supabase
                    .from("players")
                    .select("player_id,name,is_alive")
                    .eq("lobby_id", lobbyRes.data.id)
                    .order("seat_index", { ascending: true });

                if (!alive) return;

                if (playersRes.error || !playersRes.data) {
                    setFatalError(playersRes.error?.message ?? "Spieler konnten nicht geladen werden.");
                    return;
                }

                setPlayers(playersRes.data as Player[]);
                setFatalError("");
            } finally {
                inFlightRef.current = false;
            }
        }

        load();
        const t = window.setInterval(load, 700);

        return () => {
            alive = false;
            window.clearInterval(t);
        };
    }, [code, supabase]);

    // ✅ Start intro once when running begins (but render it based on server time)
    useEffect(() => {
        if (!lobby) return;

        if (lobby.phase !== "running") {
            setShowIntro(false);
            setIntroStage("countdown");
            setCountdown(5);
            introStartedForRunRef.current = false;
            setRunStartedAtMs(null);
            return;
        }

        if (introStartedForRunRef.current) return;
        // we need a server timestamp to sync
        if (!runStartedAtMs) return;

        introStartedForRunRef.current = true;
        setShowIntro(true);
    }, [lobby?.phase, runStartedAtMs]);

    // ✅ Server-anchored intro progression (no local desync)
    useEffect(() => {
        if (!showIntro) return;
        if (!runStartedAtMs) return;
        if (!lobby || lobby.phase !== "running") return;

        const COUNTDOWN_MS = 5000;
        const REVEAL_MS = 1200;

        let raf = 0;
        let t: number | null = null;

        const step = () => {
            const now = Date.now();
            const elapsed = now - runStartedAtMs;

            if (elapsed < COUNTDOWN_MS) {
                setIntroStage("countdown");
                const remainingMs = COUNTDOWN_MS - elapsed;
                const sec = Math.max(0, Math.ceil(remainingMs / 1000));
                setCountdown(sec);
            } else if (elapsed < COUNTDOWN_MS + REVEAL_MS) {
                setIntroStage("reveal");
                setCountdown(0);
            } else {
                setIntroStage("done");
                setShowIntro(false);
                return;
            }

            raf = window.requestAnimationFrame(step);
        };

        // quick start (so it reacts immediately)
        t = window.setTimeout(() => {
            raf = window.requestAnimationFrame(step);
        }, 0);

        return () => {
            if (t) window.clearTimeout(t);
            if (raf) window.cancelAnimationFrame(raf);
        };
    }, [showIntro, runStartedAtMs, lobby?.phase]);

    async function handlePass() {
        if (!mePlayerId) return;
        if (iAmEliminated) return;

        try {
            await passPotato(code, mePlayerId);
        } catch {
            // ignore
        }
    }

    if (fatalError) {
        return (
            <main style={{ minHeight: "100vh", display: "grid", placeItems: "center", padding: 24 }}>
                <div style={{ width: "min(720px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontWeight: 950, fontSize: 22 }}>⚠️ Spiel konnte nicht geladen werden</div>
                    <div style={{ marginTop: 10, opacity: 0.8 }}>{fatalError}</div>
                    <div style={{ marginTop: 18 }}>
                        <button className="btn btnPrimary btnXL" onClick={() => goLobby(code)} type="button">
                            Zurück zur Lobby
                        </button>
                    </div>
                </div>
            </main>
        );
    }

    if (!lobby) {
        return <div className="p-6 opacity-70">Lade Spiel…</div>;
    }

    // WAIT screen (before running)
    if (lobby.phase !== "running" && lobby.phase !== "finished") {
        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(243,168,59,0.35) 0%, rgba(192,106,0,0.70) 80%)",
                }}
            >
                <div style={{ width: "min(820px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>WARTEN</div>
                    <div style={{ fontSize: "clamp(28px, 4vw, 46px)", fontWeight: 950, marginTop: 12 }}>⏳ Warten auf Start…</div>
                    <div style={{ marginTop: 10, opacity: 0.78, fontWeight: 700 }}>
                        Der Host startet gleich das Spiel. Du bleibst automatisch hier.
                    </div>

                    <div style={{ display: "flex", justifyContent: "center", gap: 12, marginTop: 22 }}>
                        <button className="btn btnSecondary btnXL" onClick={() => goLobby(code)} type="button">
                            Zur Lobby
                        </button>
                    </div>
                </div>
            </main>
        );
    }

    // Intro UI (Countdown -> Reveal) — now synced via server time
    if (showIntro && lobby.phase === "running") {
        const bg = isMeHolder
            ? "radial-gradient(circle at 50% 35%, rgba(255,140,70,0.55) 0%, rgba(143,15,15,0.96) 72%)"
            : "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(243,168,59,0.55) 0%, rgba(192,106,0,0.88) 80%)";

        return (
            <main
                style={{
                    minHeight: "100vh",
                    width: "100vw",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    overflow: "hidden",
                    background: bg,
                    position: "relative",
                }}
            >
                {introStage === "countdown" ? (
                    <div
                        aria-hidden
                        style={{
                            position: "absolute",
                            inset: 0,
                            backdropFilter: "blur(10px)",
                            WebkitBackdropFilter: "blur(10px)",
                            background: "rgba(0,0,0,0.18)",
                        }}
                    />
                ) : null}

                <div style={{ textAlign: "center", width: "min(920px, 96vw)", position: "relative", zIndex: 2 }}>
                    {introStage === "countdown" ? (
                        <>
                            <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>START IN</div>
                            <div
                                style={{
                                    marginTop: 14,
                                    fontSize: "clamp(80px, 10vw, 140px)",
                                    fontWeight: 950,
                                    letterSpacing: 2,
                                    textShadow: "0 18px 70px rgba(0,0,0,0.35)",
                                }}
                            >
                                {Math.max(0, countdown)}
                            </div>
                            <div style={{ marginTop: 10, fontSize: 14, fontWeight: 800, opacity: 0.75 }}>Bereit machen…</div>
                        </>
                    ) : (
                        <>
                            <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>READY?</div>
                            <div style={{ fontSize: "clamp(44px, 6vw, 84px)", fontWeight: 950, marginTop: 12 }}>
                                {isMeHolder ? "🔥 DU STARTERST HEISS" : "🌿 BLEIB RUHIG"}
                            </div>
                            <div style={{ marginTop: 12, fontSize: 14, fontWeight: 750, opacity: 0.78 }}>
                                Holder: <b>{holderName}</b>
                            </div>
                            <div style={{ marginTop: 16, fontSize: 14, fontWeight: 700, opacity: 0.72 }}>
                                Wenn du die Kartoffel hast: <b>Leertaste</b> oder Button → weitergeben.
                            </div>
                            <div style={{ marginTop: 22, opacity: 0.7, fontWeight: 800 }}>Los!</div>
                        </>
                    )}
                </div>
            </main>
        );
    }

    // Finished screen
    if (lobby.phase === "finished") {
        const winner = lobby.holder_player_id ? players.find((p) => p.player_id === lobby.holder_player_id)?.name ?? "Unbekannt" : "Unbekannt";

        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(243,168,59,0.55) 0%, rgba(192,106,0,0.88) 80%)",
                }}
            >
                <div style={{ textAlign: "center", width: "min(900px, 96vw)" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>SPIEL BEENDET</div>
                    <div style={{ fontSize: "clamp(44px, 6vw, 82px)", fontWeight: 950, marginTop: 14 }}>🏆 {winner}</div>
                    <div style={{ marginTop: 12, fontSize: 14, fontWeight: 700, opacity: 0.75 }}>{iAmEliminated ? "Du bist raus – aber du konntest zuschauen." : "GG."}</div>
                    <div style={{ display: "flex", gap: 12, justifyContent: "center", marginTop: 22 }}>
                        <button className="btn btnPrimary btnXL" onClick={() => goLobby(code)} type="button">
                            Zur Lobby
                        </button>
                        <button className="btn btnSecondary btnXL" onClick={() => (window.location.href = "/")} type="button">
                            Hauptmenü
                        </button>
                    </div>
                </div>
            </main>
        );
    }

    return <GameBoard holderPlayerId={lobby.holder_player_id} players={players} mePlayerId={mePlayerId} onPass={handlePass} />;
}