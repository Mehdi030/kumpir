"use client";

import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabaseClient";
import { useParams, useRouter } from "next/navigation";

type Player = {
    id: string;
    name: string;
    joined_at: string;
    is_ready?: boolean;
    is_eliminated?: boolean;
};

type Lobby = {
    code: string;
    host_name: string | null;
    status?: "lobby" | "in_game" | "ended";
};

type GameState = {
    lobby_code: string;
    round: number;
    state: string;
    current_holder_player_id: string | null;
    timer_ends_at: string | null;
};

export default function LobbyPage() {
    const params = useParams<{ code: string }>();
    const router = useRouter();
    const code = String(params.code ?? "").trim();

    const [lobby, setLobby] = useState<Lobby | null>(null);
    const [players, setPlayers] = useState<Player[]>([]);
    const [gameState, setGameState] = useState<GameState | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [loading, setLoading] = useState(false);

    async function loadLobby() {
        const { data, error } = await supabase
            .from("lobbies")
            .select("code,host_name,status")
            .eq("code", code)
            .maybeSingle();

        if (error) throw new Error(error.message);
        setLobby((data as Lobby) ?? null);
    }

    async function loadPlayers() {
        const { data, error } = await supabase
            .from("players")
            .select("id,name,joined_at,is_ready,is_eliminated")
            .eq("lobby_code", code)
            .order("joined_at", { ascending: true });

        if (error) throw new Error(error.message);
        setPlayers((data as Player[]) ?? []);
    }

    async function loadGameState() {
        const { data, error } = await supabase
            .from("game_state")
            .select("lobby_code,round,state,current_holder_player_id,timer_ends_at")
            .eq("lobby_code", code)
            .maybeSingle();

        if (error) throw new Error(error.message);
        setGameState((data as GameState) ?? null);
    }

    async function refresh() {
        if (!code) return;
        setError(null);
        setLoading(true);
        try {
            await Promise.all([loadLobby(), loadPlayers(), loadGameState()]);
        } catch (e: any) {
            setError(e?.message ?? "Unknown error");
        } finally {
            setLoading(false);
        }
    }

    // sort players: host first
    const sortedPlayers = useMemo(() => {
        const hostName = lobby?.host_name?.trim();
        if (!hostName) return players;
        const host = players.filter((p) => p.name === hostName);
        const rest = players.filter((p) => p.name !== hostName);
        return [...host, ...rest];
    }, [players, lobby?.host_name]);

    // Realtime subscription + initial load
    useEffect(() => {
        if (!code) return;

        refresh();

        const lobbyCode = code.trim();
        const channel = supabase
            .channel(`lobby:${lobbyCode}`)
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "lobbies", filter: `code=eq.${lobbyCode}` },
                () => refresh()
            )
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "players", filter: `lobby_code=eq.${lobbyCode}` },
                () => refresh()
            )
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "game_state", filter: `lobby_code=eq.${lobbyCode}` },
                () => refresh()
            )
            .subscribe();

        return () => {
            supabase.removeChannel(channel);
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [code]);

    // Optional: when game starts, route to game page (adjust path if needed)
    useEffect(() => {
        if (lobby?.status === "in_game") {
            // change this route if your game page differs
            // router.push(`/game/${code}`);
        }
    }, [lobby?.status, router, code]);

    return (
        <main style={styles.page}>
            <div style={styles.headerRow}>
                <div>
                    <h1 style={styles.title}>Lobby</h1>
                    <p style={styles.subtitle}>
                        Lobby-Code: <span style={styles.codePill}>{code}</span>
                    </p>
                </div>

                <button onClick={refresh} style={styles.refreshBtn} disabled={loading}>
                    {loading ? "Lade…" : "Neu laden"}
                </button>
            </div>

            {error && <div style={styles.errorBox}>{error}</div>}

            <section style={styles.card}>
                <div style={styles.cardHeader}>
                    <div>
                        <h2 style={styles.cardTitle}>Spieler</h2>
                        <div style={styles.metaRow}>
              <span style={styles.metaItem}>
                Status:{" "}
                  <strong style={styles.metaStrong}>{lobby?.status ?? "—"}</strong>
              </span>
                            <span style={styles.metaDivider}>•</span>
                            <span style={styles.metaItem}>
                Anzahl: <strong style={styles.metaStrong}>{players.length}</strong>
              </span>
                        </div>
                    </div>

                    {lobby?.host_name ? (
                        <div style={styles.hostLine}>
                            <span style={styles.hostLabel}>Host</span>
                            <span style={styles.hostValue}>{lobby.host_name}</span>
                        </div>
                    ) : (
                        <span style={styles.mutedSmall}>Host noch nicht gesetzt</span>
                    )}
                </div>

                <div style={styles.list}>
                    {sortedPlayers.map((p) => {
                        const isHost = !!lobby?.host_name && p.name === lobby.host_name;
                        const isEliminated = !!p.is_eliminated;

                        return (
                            <div key={p.id} style={styles.listItem}>
                                <div style={styles.playerLeft}>
                                    <span style={styles.playerDot} />
                                    <span
                                        style={{
                                            ...styles.playerName,
                                            opacity: isEliminated ? 0.55 : 1,
                                            textDecoration: isEliminated ? "line-through" : "none",
                                        }}
                                    >
                    {p.name}
                  </span>
                                </div>

                                <div style={styles.badgeRow}>
                                    {isHost && <span style={styles.badgeHost}>HOST</span>}
                                    {p.is_ready === true && <span style={styles.badgeReady}>READY</span>}
                                    {isEliminated && <span style={styles.badgeOut}>OUT</span>}
                                </div>
                            </div>
                        );
                    })}

                    {players.length === 0 && (
                        <div style={{ ...styles.listItem, opacity: 0.75 }}>Noch keine Spieler…</div>
                    )}
                </div>
            </section>

            <section style={styles.cardSmall}>
                <div style={styles.cardHeaderSmall}>
                    <h2 style={styles.cardTitle}>Game State</h2>
                    <span style={styles.mutedSmall}>Live</span>
                </div>

                <div style={styles.gameGrid}>
                    <div style={styles.gameBox}>
                        <div style={styles.gameLabel}>Runde</div>
                        <div style={styles.gameValue}>{gameState?.round ?? 0}</div>
                    </div>
                    <div style={styles.gameBox}>
                        <div style={styles.gameLabel}>State</div>
                        <div style={styles.gameValue}>{gameState?.state ?? "idle"}</div>
                    </div>
                    <div style={styles.gameBox}>
                        <div style={styles.gameLabel}>Timer</div>
                        <div style={styles.gameValue}>
                            {gameState?.timer_ends_at ? new Date(gameState.timer_ends_at).toLocaleTimeString() : "—"}
                        </div>
                    </div>
                </div>
            </section>

            <p style={styles.mutedFooter}>
                Tipp: Realtime ist aktiv – die Liste aktualisiert sich automatisch. Falls nicht, prüfe in Supabase, ob Realtime
                für <code>lobbies</code>, <code>players</code>, <code>game_state</code> eingeschaltet ist.
            </p>
        </main>
    );
}

const styles: Record<string, React.CSSProperties> = {
    page: {
        padding: 24,
        maxWidth: 820,
        margin: "0 auto",
        color: "white",
    },
    headerRow: {
        display: "flex",
        alignItems: "flex-start",
        justifyContent: "space-between",
        gap: 16,
        marginBottom: 16,
    },
    title: {
        fontSize: 34,
        fontWeight: 900,
        margin: 0,
        letterSpacing: 0.3,
    },
    subtitle: {
        marginTop: 8,
        marginBottom: 0,
        opacity: 0.9,
        fontSize: 14,
    },
    codePill: {
        display: "inline-block",
        padding: "4px 10px",
        borderRadius: 999,
        border: "1px solid rgba(255,255,255,0.25)",
        background: "rgba(255,255,255,0.08)",
        fontWeight: 800,
        letterSpacing: 1,
    },
    refreshBtn: {
        padding: "10px 14px",
        borderRadius: 10,
        border: "1px solid rgba(255,255,255,0.25)",
        background: "rgba(255,255,255,0.08)",
        color: "white",
        fontWeight: 700,
        cursor: "pointer",
        minWidth: 140,
    },
    errorBox: {
        marginTop: 10,
        marginBottom: 16,
        padding: 12,
        borderRadius: 12,
        border: "1px solid rgba(255, 80, 80, 0.35)",
        background: "rgba(255, 80, 80, 0.12)",
        color: "#ffd5d5",
        fontWeight: 600,
    },
    card: {
        marginTop: 10,
        borderRadius: 16,
        border: "1px solid rgba(255,255,255,0.18)",
        background: "rgba(255,255,255,0.06)",
        boxShadow: "0 10px 30px rgba(0,0,0,0.25)",
        overflow: "hidden",
    },
    cardHeader: {
        padding: 16,
        borderBottom: "1px solid rgba(255,255,255,0.12)",
        display: "flex",
        alignItems: "baseline",
        justifyContent: "space-between",
        gap: 12,
    },
    cardTitle: {
        margin: 0,
        fontSize: 18,
        fontWeight: 800,
        letterSpacing: 0.2,
    },
    metaRow: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        marginTop: 6,
        opacity: 0.85,
        fontSize: 12,
    },
    metaItem: {},
    metaStrong: {
        fontWeight: 800,
    },
    metaDivider: { opacity: 0.6 },
    hostLine: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        opacity: 0.95,
    },
    hostLabel: {
        fontSize: 12,
        opacity: 0.75,
    },
    hostValue: {
        fontSize: 14,
        fontWeight: 800,
    },
    mutedSmall: {
        fontSize: 12,
        opacity: 0.7,
    },
    list: {
        padding: 12,
        display: "grid",
        gap: 8,
    },
    listItem: {
        padding: "12px 12px",
        borderRadius: 12,
        border: "1px solid rgba(255,255,255,0.14)",
        background: "rgba(0,0,0,0.18)",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        gap: 12,
    },
    playerLeft: {
        display: "flex",
        alignItems: "center",
        gap: 10,
        minWidth: 0,
    },
    playerDot: {
        width: 8,
        height: 8,
        borderRadius: 999,
        background: "rgba(255,255,255,0.85)",
        flexShrink: 0,
    },
    playerName: {
        fontSize: 14,
        fontWeight: 700,
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis",
    },
    badgeRow: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        flexShrink: 0,
    },
    badgeHost: {
        fontSize: 11,
        fontWeight: 900,
        letterSpacing: 1,
        padding: "6px 10px",
        borderRadius: 999,
        border: "1px solid rgba(255,255,255,0.22)",
        background: "rgba(255,255,255,0.10)",
    },
    badgeReady: {
        fontSize: 11,
        fontWeight: 900,
        letterSpacing: 1,
        padding: "6px 10px",
        borderRadius: 999,
        border: "1px solid rgba(255,255,255,0.18)",
        background: "rgba(255,255,255,0.06)",
        opacity: 0.95,
    },
    badgeOut: {
        fontSize: 11,
        fontWeight: 900,
        letterSpacing: 1,
        padding: "6px 10px",
        borderRadius: 999,
        border: "1px solid rgba(255,255,255,0.18)",
        background: "rgba(0,0,0,0.22)",
        opacity: 0.85,
    },
    cardSmall: {
        marginTop: 14,
        borderRadius: 16,
        border: "1px solid rgba(255,255,255,0.18)",
        background: "rgba(255,255,255,0.06)",
        boxShadow: "0 10px 30px rgba(0,0,0,0.25)",
        overflow: "hidden",
    },
    cardHeaderSmall: {
        padding: 16,
        borderBottom: "1px solid rgba(255,255,255,0.12)",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        gap: 12,
    },
    gameGrid: {
        padding: 12,
        display: "grid",
        gridTemplateColumns: "repeat(3, minmax(0, 1fr))",
        gap: 8,
    },
    gameBox: {
        padding: 12,
        borderRadius: 12,
        border: "1px solid rgba(255,255,255,0.14)",
        background: "rgba(0,0,0,0.18)",
    },
    gameLabel: {
        fontSize: 12,
        opacity: 0.75,
    },
    gameValue: {
        marginTop: 6,
        fontSize: 14,
        fontWeight: 800,
    },
    mutedFooter: {
        marginTop: 12,
        opacity: 0.7,
        fontSize: 12,
        lineHeight: 1.5,
    },
};
