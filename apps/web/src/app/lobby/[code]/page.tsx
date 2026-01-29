"use client";

import Link from "next/link";
import Image from "next/image";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { AuthMini } from "@/components/AuthMini";

/* =========================
   Typen (DB-konform)
========================= */

type LobbyStatus = "waiting" | "started" | "ended";

type Lobby = {
    id: string;
    code: string;
    host_player_id: string;
    status: LobbyStatus;
};

type Player = {
    id: string;          // row id
    lobby_id: string;    // FK -> lobbies.id
    player_id: string;   // DIE Player-ID
    name: string;
    ready: boolean;
    joined_at: string;
    last_seen_at: string | null;
    user_id: string | null;
};

/* =========================
   Helpers
========================= */

function getStoredPlayerId(): string | null {
    if (typeof window === "undefined") return null;
    return localStorage.getItem("kumpir_player_id");
}

function initials(name: string): string {
    const t = name.trim();
    return t ? t[0].toUpperCase() : "?";
}

/* =========================
   Page
========================= */

export default function LobbyPage({ params }: { params: { code: string } }) {
    const supabase = getSupabaseClient();
    const code = params.code.toUpperCase();

    const [playerId, setPlayerId] = useState<string | null>(() => getStoredPlayerId());
    const [lobby, setLobby] = useState<Lobby | null>(null);
    const [players, setPlayers] = useState<Player[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");

    /* =========================
       Derived State
    ========================= */

    const myRow = useMemo(
        () => players.find((p) => p.player_id === playerId) ?? null,
        [players, playerId]
    );

    const isHost = !!playerId && lobby?.host_player_id === playerId;

    const readyCount = players.filter((p) => p.ready).length;
    const totalCount = players.length;

    const canStart =
        lobby?.status === "waiting" &&
        isHost &&
        totalCount >= 2 &&
        readyCount === totalCount;

    /* =========================
       Fetch Lobby
    ========================= */

    const fetchLobby = useCallback(async () => {
        setLoading(true);
        setError("");

        const { data, error } = await supabase
            .from("lobbies")
            .select("id, code, host_player_id, status")
            .eq("code", code)
            .single();

        if (error || !data) {
            setError("Lobby nicht gefunden.");
            setLobby(null);
            setPlayers([]);
            setLoading(false);
            return;
        }

        setLobby(data as Lobby);
        setLoading(false);
    }, [supabase, code]);

    /* =========================
       Fetch Players
    ========================= */

    const fetchPlayers = useCallback(
        async (lobbyId: string) => {
            const { data } = await supabase
                .from("players")
                .select("*")
                .eq("lobby_id", lobbyId)
                .order("joined_at");

            setPlayers((data ?? []) as Player[]);
        },
        [supabase]
    );

    /* =========================
       Initial Load
    ========================= */

    useEffect(() => {
        void fetchLobby();
    }, [fetchLobby]);

    useEffect(() => {
        if (!lobby) return;
        void fetchPlayers(lobby.id);
    }, [lobby, fetchPlayers]);

    /* =========================
       Realtime (Players + Lobby)
    ========================= */

    const channelRef = useRef<ReturnType<typeof supabase.channel> | null>(null);

    useEffect(() => {
        if (!lobby || channelRef.current) return;

        channelRef.current = supabase
            .channel(`lobby:${lobby.id}`)
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "players", filter: `lobby_id=eq.${lobby.id}` },
                () => void fetchPlayers(lobby.id)
            )
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "lobbies", filter: `id=eq.${lobby.id}` },
                () => void fetchLobby()
            )
            .subscribe();

        return () => {
            if (channelRef.current) {
                void supabase.removeChannel(channelRef.current);
                channelRef.current = null;
            }
        };
    }, [supabase, lobby, fetchPlayers, fetchLobby]);

    /* =========================
       Actions
    ========================= */

    async function toggleReady() {
        if (!playerId || !myRow) return;

        const { error } = await supabase.rpc("set_ready", {
            p_player_id: playerId,
            p_ready: !myRow.ready,
        });

        if (error) setError(error.message);
    }

    async function startGame() {
        if (!playerId || !isHost || !lobby) return;

        const { error } = await supabase.rpc("start_game", {
            p_host_player_id: playerId,
        });

        if (error) setError(error.message);
    }

    /* =========================
       Redirect to Game
    ========================= */

    useEffect(() => {
        if (lobby?.status === "started") {
            window.location.href = `/game/${code}`;
        }
    }, [lobby, code]);

    /* =========================
       Render
    ========================= */

    return (
        <main className="container">
            <Link href="/" className="brandLogo">
                <Image src="/logo.png" alt="Kumpir" width={160} height={160} priority />
            </Link>

            <section className="card cardLobby">
                <header className="lobbyTop" style={{ justifyContent: "space-between", gap: 12 }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                        <h1 className="h1">Lobby</h1>
                        <div className="codePill">{code}</div>
                    </div>

                    <AuthMini nextPath={`/lobby/${code}`} variant="header" />
                </header>

                {error && <div className="errorBox">{error}</div>}
                {loading && <div>Lade Lobby…</div>}

                {!loading && lobby && (
                    <>
                        <div className="readyInfo">
                            {readyCount}/{totalCount} bereit
                        </div>

                        <div className="playerList">
                            {players.map((p) => (
                                <div key={p.id}>
                                    {initials(p.name)} {p.name} {p.ready ? "✔" : "…"}
                                    {p.player_id === lobby.host_player_id ? " (Host)" : ""}
                                </div>
                            ))}
                        </div>

                        <footer style={{ display: "flex", gap: 12 }}>
                            <button onClick={toggleReady} disabled={!playerId}>
                                {myRow?.ready ? "Bereit (aus)" : "Bereit"}
                            </button>

                            {isHost && (
                                <button onClick={startGame} disabled={!canStart}>
                                    Spiel starten
                                </button>
                            )}
                        </footer>
                    </>
                )}
            </section>
        </main>
    );
}
