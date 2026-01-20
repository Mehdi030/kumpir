"use client";

import Link from "next/link";
import Image from "next/image";
import { use, useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "@/lib/supabaseClient";

type Lobby = {
    id: string;
    code: string;
    host_player_id: string;
    status: "waiting" | "started" | "ended";
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

function getOrCreatePlayerId() {
    const key = "kumpir_player_id";
    let id = typeof window !== "undefined" ? localStorage.getItem(key) : null;
    if (!id) {
        id = crypto.randomUUID();
        localStorage.setItem(key, id);
    }
    return id;
}

function getStoredName() {
    const key = "kumpir_player_name";
    return typeof window !== "undefined" ? localStorage.getItem(key) || "" : "";
}

function setStoredName(name: string) {
    const key = "kumpir_player_name";
    localStorage.setItem(key, name);
}

function initials(name: string) {
    const t = name.trim();
    if (!t) return "?";
    return t.slice(0, 1).toUpperCase();
}

function hexToRgba(hex: string, alpha: number) {
    const h = hex.replace("#", "").trim();
    const full = h.length === 3 ? h.split("").map((c) => c + c).join("") : h;
    const r = parseInt(full.slice(0, 2), 16);
    const g = parseInt(full.slice(2, 4), 16);
    const b = parseInt(full.slice(4, 6), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

/**
 * Feste Spielerfarben:
 * - Host bekommt eine eigene (neutralere) Farbe
 * - Spieler 1 = rot, Spieler 2 = gelb, Spieler 3 = grün, ...
 */
const HOST_COLOR = "#070707";
const PLAYER_COLORS = [
    "#e10404", // Spieler 1: rot
    "#f3df03", // Spieler 2: gelb
    "#18ed07", // Spieler 3: grün
    "#0626f4", // Spieler 4: blau
    "#8407e3", // Spieler 5: lila
    "#02ece4", // Spieler 6: türkis
];

function getPlayerColor(index: number) {
    return PLAYER_COLORS[index % PLAYER_COLORS.length];
}

export default function LobbyPage({ params }: { params: Promise<{ code: string }> }) {
    const { code: raw } = use(params);
    const code = (raw || "").toUpperCase();

    const playerId = useMemo(
        () => (typeof window !== "undefined" ? getOrCreatePlayerId() : ""),
        []
    );

    const [name, setName] = useState("");
    const [nameTouched, setNameTouched] = useState(false);

    const [lobby, setLobby] = useState<Lobby | null>(null);
    const [players, setPlayers] = useState<LobbyPlayer[]>([]);
    const [loadingLobby, setLoadingLobby] = useState(true);
    const [loadingPlayers, setLoadingPlayers] = useState(true);
    const [joining, setJoining] = useState(false);
    const [error, setError] = useState<string>("");

    const nameInputRef = useRef<HTMLInputElement | null>(null);

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

    const hostRow = useMemo(() => {
        if (!lobby) return null;
        return players.find((p) => p.player_id === lobby.host_player_id) || null;
    }, [players, lobby]);

    const others = useMemo(() => {
        if (!lobby) return [];
        return players.filter((p) => p.player_id !== lobby.host_player_id);
    }, [players, lobby]);

    // Load stored name on mount
    useEffect(() => {
        const stored = getStoredName();
        if (stored) setName(stored);
    }, []);

    // 1) Load lobby by code (READ is fine)
    useEffect(() => {
        let alive = true;

        async function loadLobby() {
            setLoadingLobby(true);
            setError("");

            const { data, error } = await supabase
                .from("lobbies")
                .select("*")
                .eq("code", code)
                .single();

            if (!alive) return;

            if (error || !data) {
                setLobby(null);
                setPlayers([]);
                setError("Lobby nicht gefunden. Prüfe den Code oder erstelle eine neue Lobby.");
                setLoadingLobby(false);
                return;
            }

            setLobby(data as Lobby);
            setLoadingLobby(false);
        }

        if (code) loadLobby();

        return () => {
            alive = false;
        };
    }, [code]);

    // 2) Join via RPC (keine direkten Tabellen-Writes mehr)
    useEffect(() => {
        if (!lobby) return;
        if (!isNameValid) return;

        let alive = true;

        async function join() {
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
                setError(rpcErr.message || "Konnte der Lobby nicht beitreten. Bitte neu laden.");
            }

            setJoining(false);
        }

        join();

        return () => {
            alive = false;
        };
    }, [lobby?.id, isNameValid, name, playerId, code]);

    // 3) Players fetch + Realtime
    useEffect(() => {
        if (!lobby) return;

        let channel: ReturnType<typeof supabase.channel> | null = null;
        let alive = true;

        async function fetchPlayers() {
            setLoadingPlayers(true);

            const { data, error } = await supabase
                .from("lobby_players")
                .select("*")
                .eq("lobby_id", lobby.id)
                .order("joined_at", { ascending: true });

            if (!alive) return;

            if (!error) setPlayers((data || []) as LobbyPlayer[]);
            setLoadingPlayers(false);
        }

        async function fetchLobby() {
            const { data } = await supabase
                .from("lobbies")
                .select("*")
                .eq("id", lobby.id)
                .single();

            if (data) setLobby(data as Lobby);
        }

        fetchPlayers();

        channel = supabase
            .channel(`lobby:${lobby.id}`)
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "lobby_players", filter: `lobby_id=eq.${lobby.id}` },
                () => fetchPlayers()
            )
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "lobbies", filter: `id=eq.${lobby.id}` },
                () => fetchLobby()
            )
            .subscribe();

        return () => {
            alive = false;
            if (channel) supabase.removeChannel(channel);
        };
    }, [lobby?.id]);

    async function copyCode() {
        try {
            await navigator.clipboard.writeText(code);
        } catch {
            // ignore
        }
    }

    async function toggleReady() {
        if (!lobby) return;

        const { error: rpcErr } = await supabase.rpc("rpc_toggle_ready", {
            p_lobby_id: lobby.id,
            p_player_id: playerId,
            p_ready: null, // togglet automatisch
        });

        if (rpcErr) {
            setError(rpcErr.message || "Konnte Ready-Status nicht ändern.");
        }
    }

    async function startGame() {
        if (!lobby || !isHost || !canStart) return;

        const { error: rpcErr } = await supabase.rpc("rpc_start_game", {
            p_lobby_id: lobby.id,
            p_player_id: playerId,
        });

        if (rpcErr) {
            setError(rpcErr.message || "Konnte Spiel nicht starten.");
            return;
        }

        window.location.href = `/game/${code}`;
    }

    const readyChipLabel =
        loadingPlayers && !totalCount ? "—/— bereit" : `${readyCount}/${totalCount || "—"} bereit`;

    return (
        <main className="container">
            <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
                <Image
                    src="/logo.png"
                    alt="Kumpir Maskottchen"
                    width={160}
                    height={160}
                    priority
                    className="brandLogoImg"
                />
            </Link>

            <section className="card cardLobby" aria-label="Lobby">
                {/* HEADER */}
                <header className="lobbyTop">
                    <div>
                        <h1 className="h1">Kumpir</h1>
                        <p className="subline">Das Spiel, bei dem Geben dein Leben rettet.</p>
                    </div>

                    {/* Code bleibt grau – nur Text RGB */}
                    <div className="codePill">
                        <span className="rgbText">{code}</span>
                    </div>

                    <button type="button" className="btn btnSecondary btnTiny" onClick={copyCode}>
                        <span className="rgbText">Code kopieren</span>
                    </button>
                </header>

                {/* ERROR / LOBBY LOADING */}
                {error ? (
                    <div className="playerList">
                        <div className="emptyRow">{error}</div>
                    </div>
                ) : null}

                {loadingLobby ? (
                    <div className="playerList">
                        <div className="emptyRow">Lade Lobby…</div>
                    </div>
                ) : null}

                {!loadingLobby && lobby ? (
                    <>
                        {/* NAME GATE */}
                        {showNameGate ? (
                            <div className="playerList">
                                <div className="playerListHead">
                                    <div className="playerListTitle">Dein Name</div>
                                    <div className="playerListHint">Mindestens 2 Zeichen.</div>
                                </div>

                                <div className="fieldControl">
                                    <input
                                        ref={nameInputRef}
                                        className={`input ${nameTouched && !isNameValid ? "inputError" : ""}`}
                                        value={name}
                                        onChange={(e) => setName(e.target.value)}
                                        onBlur={() => setNameTouched(true)}
                                        placeholder="z.B. Medo"
                                        autoComplete="nickname"
                                        maxLength={24}
                                    />
                                </div>

                                <div className={`fieldHelp ${nameTouched && !isNameValid ? "fieldHelpError" : ""}`}>
                                    {nameTouched && !isNameValid ? "Mindestens 2 Zeichen." : "So sehen dich andere Spieler."}
                                </div>
                            </div>
                        ) : null}

                        {/* BODY */}
                        <div className="lobbyBody">
                            {/* HOST CARD */}
                            <div className="hostCard">
                                <div className="hostLeft">
                                    <div
                                        className={`avatarBig ${!hostRow ? "skeleton" : ""}`}
                                        aria-hidden
                                        style={
                                            hostRow
                                                ? {
                                                    background: hexToRgba(HOST_COLOR, 0.18),
                                                    borderColor: hexToRgba(HOST_COLOR, 0.35),
                                                    color: HOST_COLOR,
                                                }
                                                : undefined
                                        }
                                    >
                                        {hostRow ? initials(hostRow.name) : ""}
                                    </div>

                                    <div className="hostMeta">
                                        <div className="hostLabel">Host</div>

                                        <div
                                            className={`hostName ${!hostRow ? "skeletonLine" : ""}`}
                                            style={hostRow ? { color: HOST_COLOR } : undefined}
                                        >
                                            {hostRow ? hostRow.name : "Lade Host…"}
                                        </div>

                                        <div className="hostSub">
                                            Status:{" "}
                                            <span className={hostRow?.ready ? "statusOk" : "statusIdle"}>
                        {hostRow ? (hostRow.ready ? "Bereit" : "Nicht bereit") : "—"}
                      </span>
                                            <span className="dotSep">•</span>
                                            <span className="mutedMini">{lobby.privacy === "private" ? "🔒 Privat" : "🌐 Public"}</span>
                                            <span className="dotSep">•</span>
                                            <span className="mutedMini">👥 bis {lobby.max_players}</span>
                                        </div>
                                    </div>
                                </div>

                                <div className="hostRight">
                  <span className="chip" aria-label={readyChipLabel}>
                    <span
                        className="chipDot"
                        aria-hidden
                        style={{
                            background:
                                !loadingPlayers && totalCount > 0 && readyCount === totalCount
                                    ? "rgba(34,211,238,.92)"
                                    : "rgba(255,255,255,.35)",
                            boxShadow:
                                !loadingPlayers && totalCount > 0 && readyCount === totalCount
                                    ? "0 0 0 3px rgba(34,211,238,.18)"
                                    : "0 0 0 3px rgba(255,255,255,.10)",
                        }}
                    />
                      {readyChipLabel}
                  </span>
                                </div>
                            </div>

                            {/* PLAYERS LIST */}
                            <div className="playerList">
                                <div className="playerListHead">
                                    <div className="playerListTitle">Spieler</div>
                                    <div className="playerListHint">
                                        {loadingPlayers ? "Lade Spieler…" : joining ? "Verbinde…" : "Warte bis alle bereit sind."}
                                    </div>
                                </div>

                                <div className="playerRows">
                                    {loadingPlayers ? (
                                        <>
                                            <div className="playerRow">
                                                <div className="playerLeft">
                                                    <div className="avatar skeleton" aria-hidden />
                                                    <div className="playerName skeletonLine" style={{ width: "40%" }} />
                                                </div>
                                                <div className="playerRight">
                                                    <span className="readyPill readyOff">…</span>
                                                </div>
                                            </div>
                                            <div className="playerRow">
                                                <div className="playerLeft">
                                                    <div className="avatar skeleton" aria-hidden />
                                                    <div className="playerName skeletonLine" style={{ width: "55%" }} />
                                                </div>
                                                <div className="playerRight">
                                                    <span className="readyPill readyOff">…</span>
                                                </div>
                                            </div>
                                        </>
                                    ) : others.length === 0 ? (
                                        <div className="emptyRow">Noch keine Mitspieler – teile den Code.</div>
                                    ) : (
                                        others.map((p, index) => (
                                            <div key={p.id} className="playerRow">
                                                <div className="playerLeft">
                                                    <div className="avatar" aria-hidden>
                                                        {initials(p.name)}
                                                    </div>
                                                    <div className="playerName" style={{ color: getPlayerColor(index) }}>
                                                        {p.name}
                                                    </div>
                                                </div>

                                                <div className="playerRight">
                          <span className={`readyPill ${p.ready ? "readyOn" : "readyOff"}`}>
                            {p.ready ? "Bereit" : "Wartet"}
                          </span>
                                                </div>
                                            </div>
                                        ))
                                    )}
                                </div>
                            </div>
                        </div>

                        {/* ACTIONS */}
                        <footer className="lobbyActions">
                            {isHost ? (
                                <button
                                    type="button"
                                    className={`btn btnPrimary ${!canStart ? "btnDisabled" : ""}`}
                                    onClick={startGame}
                                    disabled={!canStart || showNameGate}
                                    title={!canStart ? "Mindestens 2 Spieler und alle bereit." : ""}
                                >
                                    Spiel starten
                                </button>
                            ) : (
                                <button
                                    type="button"
                                    className={`btn btnPrimary ${showNameGate ? "btnDisabled" : ""}`}
                                    onClick={toggleReady}
                                    disabled={showNameGate || !myRow}
                                    title={showNameGate ? "Bitte erst Name setzen." : ""}
                                >
                                    {myRow?.ready ? "Bereit (aus)" : "Bereit"}
                                </button>
                            )}

                            <Link href="/" className="btn btnSecondary">
                                Lobby verlassen
                            </Link>
                        </footer>
                    </>
                ) : null}
            </section>
        </main>
    );
}
