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

    const inFlightTickRef = useRef(false);

    // Intro flow
    const [showIntro, setShowIntro] = useState(true);
    const [introStage, setIntroStage] = useState<IntroStage>("countdown");
    const [countdown, setCountdown] = useState(5);

    const introStartedRef = useRef(false);

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
            if (inFlightTickRef.current) return;
            inFlightTickRef.current = true;

            try {
                try {
                    await tickGame(code);
                } catch {
                    // ignore
                }

                const lobbyRes = await supabase
                    .from("lobbies")
                    .select("id, holder_player_id, phase")
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
                };

                setLobby(nextLobby);

                // ✅ FIX: Wenn nicht running, zurück zur Lobby (nicht im Game hängen)
                if (nextLobby.phase !== "running" && nextLobby.phase !== "finished") {
                    goLobby(code);
                    return;
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
                inFlightTickRef.current = false;
            }
        }

        load();
        const t = window.setInterval(load, 700);

        return () => {
            alive = false;
            window.clearInterval(t);
        };
    }, [code, supabase]);

    useEffect(() => {
        if (!lobby) return;
        if (introStartedRef.current) return;

        if (lobby.phase === "finished") {
            setShowIntro(false);
            introStartedRef.current = true;
            return;
        }

        introStartedRef.current = true;
        setShowIntro(true);
        setIntroStage("countdown");
        setCountdown(5);
    }, [lobby]);

    useEffect(() => {
        if (!showIntro) return;

        if (introStage === "countdown") {
            if (countdown <= 0) {
                setIntroStage("reveal");
                return;
            }

            const t = window.setTimeout(() => {
                setCountdown((c) => c - 1);
            }, 1000);

            return () => window.clearTimeout(t);
        }

        if (introStage === "reveal") {
            const t = window.setTimeout(() => {
                setIntroStage("done");
                setShowIntro(false);
            }, 1200);

            return () => window.clearTimeout(t);
        }

        return;
    }, [countdown, introStage, showIntro]);

    async function handlePass() {
        if (!mePlayerId) return;
        if (iAmEliminated) return;

        try {
            await passPotato(code, mePlayerId);
        } catch {
            // ok
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

    if (showIntro && lobby.phase !== "finished") {
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

    if (lobby.phase === "finished") {
        const winner = lobby.holder_player_id
            ? players.find((p) => p.player_id === lobby.holder_player_id)?.name ?? "Unbekannt"
            : "Unbekannt";

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
                    <div style={{ marginTop: 12, fontSize: 14, fontWeight: 700, opacity: 0.75 }}>
                        {iAmEliminated ? "Du bist raus – aber du konntest zuschauen." : "GG."}
                    </div>
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