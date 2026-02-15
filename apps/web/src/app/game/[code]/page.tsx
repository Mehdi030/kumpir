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

    const meRow = useMemo(() => {
        if (!mePlayerId) return null;
        return players.find((p) => p.player_id === mePlayerId) ?? null;
    }, [players, mePlayerId]);

    const iAmEliminated = !!meRow && !meRow.is_alive;

    useEffect(() => {
        let alive = true;

        async function load() {
            if (inFlightRef.current) return;
            inFlightRef.current = true;

            try {
                try {
                    await tickGame(code);
                } catch {
                    // ignore tick errors
                }

                const lobbyRes = await supabase
                    .from("lobbies")
                    .select("id, holder_player_id, phase")
                    .eq("code", code)
                    .single();

                if (!alive) return;

                if (lobbyRes.error || !lobbyRes.data) {
                    setFatalError(
                        lobbyRes.error?.message ?? "Lobby konnte nicht geladen werden."
                    );
                    return;
                }

                const nextLobby: LobbyState = {
                    id: lobbyRes.data.id,
                    holder_player_id: lobbyRes.data.holder_player_id,
                    phase: lobbyRes.data.phase,
                };

                setLobby(nextLobby);

                const playersRes = await supabase
                    .from("players")
                    .select("player_id,name,is_alive")
                    .eq("lobby_id", lobbyRes.data.id)
                    .order("seat_index", { ascending: true });

                if (!alive) return;

                if (playersRes.error || !playersRes.data) {
                    setFatalError(
                        playersRes.error?.message ??
                        "Spieler konnten nicht geladen werden."
                    );
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
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                }}
            >
                <div style={{ width: "min(720px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontWeight: 950, fontSize: 22 }}>
                        ⚠️ Spiel konnte nicht geladen werden
                    </div>
                    <div style={{ marginTop: 10, opacity: 0.8 }}>
                        {fatalError}
                    </div>
                    <div style={{ marginTop: 18 }}>
                        <button
                            className="btn btnPrimary btnXL"
                            onClick={() => goLobby(code)}
                            type="button"
                        >
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

    // Waiting screen (before running)
    if (lobby.phase !== "running" && lobby.phase !== "finished") {
        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                }}
            >
                <div style={{ width: "min(820px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, opacity: 0.75 }}>
                        WARTEN
                    </div>
                    <div
                        style={{
                            fontSize: "clamp(28px, 4vw, 46px)",
                            fontWeight: 950,
                            marginTop: 12,
                        }}
                    >
                        ⏳ Warten auf Start…
                    </div>

                    <div style={{ marginTop: 22 }}>
                        <button
                            className="btn btnSecondary btnXL"
                            onClick={() => goLobby(code)}
                            type="button"
                        >
                            Zur Lobby
                        </button>
                    </div>
                </div>
            </main>
        );
    }

    // Finished screen
    if (lobby.phase === "finished") {
        const winner = lobby.holder_player_id
            ? players.find(
            (p) => p.player_id === lobby.holder_player_id
        )?.name ?? "Unbekannt"
            : "Unbekannt";

        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                }}
            >
                <div style={{ textAlign: "center", width: "min(900px, 96vw)" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, opacity: 0.75 }}>
                        SPIEL BEENDET
                    </div>

                    <div
                        style={{
                            fontSize: "clamp(44px, 6vw, 82px)",
                            fontWeight: 950,
                            marginTop: 14,
                        }}
                    >
                        🏆 {winner}
                    </div>

                    <div style={{ marginTop: 12, opacity: 0.75 }}>
                        {iAmEliminated
                            ? "Du bist raus – aber du konntest zuschauen."
                            : "GG."}
                    </div>

                    <div
                        style={{
                            display: "flex",
                            gap: 12,
                            justifyContent: "center",
                            marginTop: 22,
                        }}
                    >
                        <button
                            className="btn btnPrimary btnXL"
                            onClick={() => goLobby(code)}
                            type="button"
                        >
                            Zur Lobby
                        </button>
                        <button
                            className="btn btnSecondary btnXL"
                            onClick={() => (window.location.href = "/")}
                            type="button"
                        >
                            Hauptmenü
                        </button>
                    </div>
                </div>
            </main>
        );
    }

    return (
        <GameBoard
            holderPlayerId={lobby.holder_player_id}
            players={players}
            mePlayerId={mePlayerId}
            onPass={handlePass}
        />
    );
}