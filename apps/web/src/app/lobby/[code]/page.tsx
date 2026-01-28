"use client";

import Link from "next/link";
import Image from "next/image";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { AuthMini } from "@/components/AuthMini";

type LobbyStatus = "waiting" | "started" | "ended";

type Lobby = {
    id: string;
    code: string;
    host_player_id: string | null;
    status: LobbyStatus;
    privacy: string | null;
    max_players: number | null;
    round_seconds: number | null;
    created_at: string;
    last_activity_at: string | null;
};

type Player = {
    id: string;
    lobby_code: string;
    name: string;
    is_ready: boolean;
    is_connected: boolean;
    joined_at: string;
    last_seen_at: string | null;
};

function getPlayerId(): string | null {
    return typeof window !== "undefined" ? localStorage.getItem("kumpir_player_id") : null;
}

function getStoredName(): string {
    return typeof window !== "undefined" ? localStorage.getItem("kumpir_player_name") || "" : "";
}

function setStoredPlayerId(id: string) {
    localStorage.setItem("kumpir_player_id", id);
}

function initials(name: string): string {
    const t = name.trim();
    return t ? t.slice(0, 1).toUpperCase() : "?";
}

const PLAYER_COLORS = ["#e10404", "#f3df03", "#18ed07", "#0626f4", "#8407e3", "#02ece4"];
function getPlayerColor(index: number): string {
    return PLAYER_COLORS[index % PLAYER_COLORS.length];
}

export default function LobbyPage({ params }: { params: { code: string } }) {
    const supabase = getSupabaseClient();
    const code = params.code.toUpperCase();

    const [playerId, setPlayerIdState] = useState<string | null>(null);
    const [lobby, setLobby] = useState<Lobby | null>(null);
    const [players, setPlayers] = useState<Player[]>([]);
    const [loadingLobby, setLoadingLobby] = useState(true);
    const [loadingPlayers, setLoadingPlayers] = useState(true);
    const [joining, setJoining] = useState(false);
    const [error, setError] = useState("");

    useEffect(() => {
        setPlayerIdState(getPlayerId());
    }, []);

    const myRow = useMemo(() => players.find((p) => p.id === playerId) ?? null, [players, playerId]);

    const isHost = !!playerId && lobby?.host_player_id === playerId;

    const connectedPlayers = useMemo(() => players.filter((p) => p.is_connected), [players]);

    const readyCount = connectedPlayers.filter((p) => p.is_ready).length;
    const totalCount = connectedPlayers.length;

    const canStart = !!lobby && lobby.status === "lobby" && totalCount >= 2 && readyCount === totalCount;

    const others = useMemo(() => players.filter((p) => p.id !== lobby?.host_player_id), [players, lobby]);

    const fetchLobby = useCallback(async () => {
        setLoadingLobby(true);
        setError("");

        const { data, error: err } = await supabase.from("lobbies").select("*").eq("code", code).single();

        if (err || !data) {
            setLobby(null);
            setPlayers([]);
            setError("Lobby nicht gefunden.");
            setLoadingLobby(false);
            return;
        }

        setLobby(data as Lobby);
        setLoadingLobby(false);
    }, [supabase, code]);

    const fetchPlayers = useCallback(async () => {
        setLoadingPlayers(true);

        const { data } = await supabase.from("players").select("*").eq("lobby_code", code).order("joined_at");

        setPlayers((data ?? []) as Player[]);
        setLoadingPlayers(false);
    }, [supabase, code]);

    useEffect(() => {
        void fetchLobby();
    }, [fetchLobby]);

    useEffect(() => {
        if (!lobby || loadingLobby) return;

        const pid = getPlayerId();

        if (!pid) {
            setError("Du bist nicht beigetreten. Geh zurück und tritt der Lobby bei.");
            return;
        }

        if (playerId !== pid) setPlayerIdState(pid);

        const ensureJoined = async () => {
            setJoining(true);
            setError("");

            const { data: me } = await supabase.from("players").select("id").eq("id", pid).maybeSingle();

            if (me?.id) {
                setJoining(false);
                return;
            }

            const storedName = getStoredName().trim();
            if (storedName.length < 2) {
                setJoining(false);
                setError("Name fehlt. Geh zurück und tritt neu bei.");
                return;
            }

            const { data, error: rpcErr } = await supabase.rpc("join_lobby", {
                p_lobby_code: code,
                p_name: storedName,
            });

            if (rpcErr) {
                setJoining(false);
                setError(rpcErr.message);
                return;
            }

            const newId = String(data);
            setStoredPlayerId(newId);
            setPlayerIdState(newId);
            setJoining(false);
        };

        void ensureJoined();
    }, [lobby, loadingLobby, supabase, code, playerId]);

    useEffect(() => {
        if (!lobby) return;

        void fetchPlayers();

        const channel = supabase
            .channel(`lobby:${code}`)
            .on("postgres_changes", { event: "*", schema: "public", table: "players", filter: `lobby_code=eq.${code}` }, () =>
                void fetchPlayers()
            )
            .on("postgres_changes", { event: "*", schema: "public", table: "lobbies", filter: `code=eq.${code}` }, () =>
                void fetchLobby()
            )
            .subscribe();

        return () => {
            void supabase.removeChannel(channel);
        };
    }, [lobby, supabase, code, fetchPlayers, fetchLobby]);

    useEffect(() => {
        if (lobby?.status === "in_game") {
            window.location.href = `/game/${code}`;
        }
    }, [lobby?.status, code]);

    async function toggleReady(): Promise<void> {
        if (!playerId || !lobby) return;

        setError("");
        const next = !(myRow?.is_ready ?? false);

        const { error: rpcErr } = await supabase.rpc("set_ready", {
            p_player_id: playerId,
            p_ready: next,
        });

        if (rpcErr) setError(rpcErr.message);
    }

    async function startGame(): Promise<void> {
        if (!playerId || !lobby || !isHost || !canStart) return;

        setError("");
        const { error: rpcErr } = await supabase.rpc("start_game", {
            p_host_player_id: playerId,
        });

        if (rpcErr) setError(rpcErr.message);
    }

    async function leaveLobby(): Promise<void> {
        if (!playerId) return;

        setError("");
        await supabase.rpc("leave_lobby", { p_player_id: playerId });

        localStorage.removeItem("kumpir_player_id");
        window.location.href = "/join";
    }

    const readyLabel = loadingPlayers ? "—/— bereit" : `${readyCount}/${totalCount} bereit`;

    return (
        <main className="container">
            <Link href="/" className="brandLogo">
                <Image src="/logo.png" alt="Kumpir" width={160} height={160} priority />
            </Link>

            <section className="card cardLobby">
                <header className="lobbyTop" style={{ justifyContent: "space-between", gap: 12 }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                        <h1 className="h1">Kumpir</h1>
                        <div className="codePill">{code}</div>
                    </div>

                    {/* ✅ vor Spielstart sichtbar */}
                    <AuthMini nextPath={`/lobby/${code}`} variant="header" />
                </header>

                {error && <div className="errorBox">{error}</div>}
                {loadingLobby && <div>Lade Lobby…</div>}

                {!loadingLobby && lobby && (
                    <>
                        <div className="readyInfo">{readyLabel}</div>
                        {joining && <div className="p subline">Verbinde…</div>}

                        <div className="playerList">
                            {lobby.host_player_id && (
                                <div style={{ color: "#070707" }}>
                                    {(() => {
                                        const host = players.find((p) => p.id === lobby.host_player_id);
                                        if (!host) return "Host …";
                                        return `${initials(host.name)} ${host.name} ${host.is_ready ? "✔" : "…"} (Host)`;
                                    })()}
                                </div>
                            )}

                            {others.map((p, i) => (
                                <div key={p.id} style={{ color: getPlayerColor(i) }}>
                                    {initials(p.name)} {p.name} {p.is_ready ? "✔" : "…"}
                                    {!p.is_connected ? " (offline)" : ""}
                                </div>
                            ))}
                        </div>

                        <footer style={{ display: "flex", gap: 12 }}>
                            <button onClick={toggleReady} disabled={!playerId || lobby.status !== "lobby"}>
                                {myRow?.is_ready ? "Bereit (aus)" : "Bereit"}
                            </button>

                            {isHost && (
                                <button onClick={startGame} disabled={!canStart || lobby.status !== "lobby"}>
                                    Spiel starten
                                </button>
                            )}

                            <button onClick={leaveLobby} disabled={!playerId}>
                                Verlassen
                            </button>
                        </footer>
                    </>
                )}
            </section>
        </main>
    );
}
