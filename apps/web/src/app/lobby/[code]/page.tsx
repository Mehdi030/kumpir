"use client";

import Link from "next/link";
import Image from "next/image";
import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

/* =======================
   Types
======================= */

type LobbyStatus = "waiting" | "started" | "ended";

type Lobby = {
    id: string;
    code: string;
    host_player_id: string;
    status: LobbyStatus;
    privacy: string;
    max_players: number;
    round_seconds: number;
    created_at: string;
};

type LobbyPlayer = {
    id: string;
    lobby_id: string;
    player_id: string;
    name: string;
    ready: boolean;
    joined_at: string;
    last_seen_at: string;
};

/* =======================
   Helpers
======================= */

function getOrCreatePlayerId(): string {
    const key = "kumpir_player_id";
    const existing = typeof window !== "undefined" ? localStorage.getItem(key) : null;
    if (existing) return existing;

    const id = crypto.randomUUID();
    localStorage.setItem(key, id);
    return id;
}

function getStoredName(): string {
    return typeof window !== "undefined"
        ? localStorage.getItem("kumpir_player_name") || ""
        : "";
}

function setStoredName(name: string): void {
    localStorage.setItem("kumpir_player_name", name);
}

function initials(name: string): string {
    const t = name.trim();
    return t ? t.slice(0, 1).toUpperCase() : "?";
}

function hexToRgba(hex: string, alpha: number): string {
    const h = hex.replace("#", "");
    const r = parseInt(h.slice(0, 2), 16);
    const g = parseInt(h.slice(2, 4), 16);
    const b = parseInt(h.slice(4, 6), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

const HOST_COLOR = "#070707";
const PLAYER_COLORS = ["#e10404", "#f3df03", "#18ed07", "#0626f4", "#8407e3", "#02ece4"];

function getPlayerColor(index: number): string {
    return PLAYER_COLORS[index % PLAYER_COLORS.length];
}

/* =======================
   Page
======================= */

export default function LobbyPage({ params }: { params: { code: string } }) {
    const supabase = getSupabaseClient();

    const code = params.code.toUpperCase();
    const playerId = useMemo(() => getOrCreatePlayerId(), []);

    const [name, setName] = useState<string>("");
    const [nameTouched, setNameTouched] = useState(false);

    const [lobby, setLobby] = useState<Lobby | null>(null);
    const [players, setPlayers] = useState<LobbyPlayer[]>([]);
    const [loadingLobby, setLoadingLobby] = useState(true);
    const [loadingPlayers, setLoadingPlayers] = useState(true);
    const [joining, setJoining] = useState(false);
    const [error, setError] = useState("");

    const nameInputRef = useRef<HTMLInputElement | null>(null);
    const joinedOnceRef = useRef(false);

    const isNameValid = name.trim().length >= 2;
    const showNameGate = !isNameValid;

    const myRow = players.find((p) => p.player_id === playerId);
    const isHost = lobby?.host_player_id === playerId;

    const readyCount = players.filter((p) => p.ready).length;
    const totalCount = players.length;

    const canStart =
        !!lobby &&
        lobby.status === "waiting" &&
        totalCount >= 2 &&
        readyCount === totalCount;

    const hostRow = useMemo(
        () => players.find((p) => p.player_id === lobby?.host_player_id) ?? null,
        [players, lobby]
    );

    const others = useMemo(
        () => players.filter((p) => p.player_id !== lobby?.host_player_id),
        [players, lobby]
    );

    /* =======================
       Effects
    ======================= */

    useEffect(() => {
        setName(getStoredName());
    }, []);

    // Load lobby
    useEffect(() => {
        let alive = true;

        async function loadLobby(): Promise<void> {
            setLoadingLobby(true);
            setError("");

            const { data, error: err } = await supabase
                .from("lobbies")
                .select("*")
                .eq("code", code)
                .single();

            if (!alive) return;

            if (err || !data) {
                setLobby(null);
                setPlayers([]);
                setError("Lobby nicht gefunden.");
                setLoadingLobby(false);
                return;
            }

            setLobby(data as Lobby);
            setLoadingLobby(false);
            joinedOnceRef.current = false;
        }

        void loadLobby();
        return () => {
            alive = false;
        };
    }, [code, supabase]);

    // Join lobby (RPC)
    useEffect(() => {
        if (!lobby?.id || !isNameValid || joinedOnceRef.current) return;

        let alive = true;

        async function join(): Promise<void> {
            setJoining(true);
            setError("");

            const trimmed = name.trim();
            setStoredName(trimmed);

            const { error: rpcErr } = await supabase.rpc("rpc_join_lobby", {
                p_code: code,
                p_player_id: playerId,
                p_name: trimmed,
            });

            if (!alive) return;

            if (rpcErr) {
                setError(rpcErr.message);
                setJoining(false);
                return;
            }

            joinedOnceRef.current = true;
            setJoining(false);
        }

        void join();
        return () => {
            alive = false;
        };
    }, [lobby?.id, isNameValid, name, code, playerId, supabase]);

    // Players + Realtime
    useEffect(() => {
        if (!lobby?.id) return;

        let alive = true;

        async function fetchPlayers(): Promise<void> {
            setLoadingPlayers(true);
            const { data } = await supabase
                .from("lobby_players")
                .select("*")
                .eq("lobby_id", lobby.id)
                .order("joined_at");

            if (!alive) return;
            setPlayers((data ?? []) as LobbyPlayer[]);
            setLoadingPlayers(false);
        }

        async function fetchLobby(): Promise<void> {
            const { data } = await supabase
                .from("lobbies")
                .select("*")
                .eq("id", lobby.id)
                .single();

            if (alive && data) setLobby(data as Lobby);
        }

        void fetchPlayers();

        const channel = supabase
            .channel(`lobby:${lobby.id}`)
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "lobby_players", filter: `lobby_id=eq.${lobby.id}` },
                () => void fetchPlayers()
            )
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "lobbies", filter: `id=eq.${lobby.id}` },
                () => void fetchLobby()
            )
            .subscribe();

        return () => {
            alive = false;
            void supabase.removeChannel(channel);
        };
    }, [lobby?.id, supabase]);

    /* =======================
       Actions
    ======================= */

    async function toggleReady(): Promise<void> {
        if (!lobby?.id) return;

        const { error: rpcErr } = await supabase.rpc("rpc_toggle_ready", {
            p_lobby_id: lobby.id,
            p_player_id: playerId,
            p_ready: null,
        });

        if (rpcErr) setError(rpcErr.message);
    }

    async function startGame(): Promise<void> {
        if (!lobby || !isHost || !canStart) return;

        const { error: rpcErr } = await supabase.rpc("rpc_start_game", {
            p_lobby_id: lobby.id,
            p_player_id: playerId,
        });

        if (!rpcErr) {
            window.location.href = `/game/${code}`;
        } else {
            setError(rpcErr.message);
        }
    }

    /* =======================
       Render
    ======================= */

    const readyLabel = loadingPlayers
        ? "—/— bereit"
        : `${readyCount}/${totalCount} bereit`;

    return (
        <main className="container">
            <Link href="/" className="brandLogo">
                <Image src="/logo.png" alt="Kumpir" width={160} height={160} priority />
            </Link>

            <section className="card cardLobby">
                <header className="lobbyTop">
                    <h1 className="h1">Kumpir</h1>
                    <div className="codePill">{code}</div>
                </header>

                {error && <div className="errorBox">{error}</div>}

                {loadingLobby && <div>Lade Lobby…</div>}

                {!loadingLobby && lobby && (
                    <>
                        {showNameGate && (
                            <div className="nameGate">
                                <input
                                    ref={nameInputRef}
                                    value={name}
                                    onChange={(e) => setName(e.target.value)}
                                    onBlur={() => setNameTouched(true)}
                                    placeholder="Dein Name"
                                />
                            </div>
                        )}

                        <div className="playerList">
                            <div className="readyInfo">{readyLabel}</div>

                            {others.map((p, i) => (
                                <div key={p.id} style={{ color: getPlayerColor(i) }}>
                                    {initials(p.name)} {p.name} {p.ready ? "✔" : "…"}
                                </div>
                            ))}
                        </div>

                        <footer>
                            {isHost ? (
                                myRow?.ready ? (
                                    <button disabled={!canStart} onClick={startGame}>
                                        Spiel starten
                                    </button>
                                ) : (
                                    <button onClick={toggleReady}>Bereit</button>
                                )
                            ) : (
                                <button onClick={toggleReady}>
                                    {myRow?.ready ? "Bereit (aus)" : "Bereit"}
                                </button>
                            )}
                        </footer>
                    </>
                )}
            </section>
        </main>
    );
}
