"use client";

import Link from "next/link";
import { startGame, type StartGameResult } from "@/actions/startGame";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";
import { useHeartbeat } from "@/hooks/useHeartbeat";
import { useLobbyRealtime } from "@/hooks/useLobbyRealtime";
import { Spinner } from "@/components/Spinner";

type ModeKey = "original" | "teleport" | "reverse";

const MODES: Record<ModeKey, { label: string; icon: string }> = {
    original: { label: "Original", icon: "🥔" },
    teleport: { label: "Teleport", icon: "🌀" },
    reverse: { label: "Reverse", icon: "🔁" },
};

function fmtJoinLink(origin: string, code: string) {
    return `${origin}/join?code=${encodeURIComponent(code)}`;
}

function getErrorMessage(e: unknown): string {
    if (e instanceof Error) return e.message;
    if (typeof e === "string") return e;
    try {
        return JSON.stringify(e);
    } catch {
        return "Unbekannter Fehler";
    }
}

function clearMyIdentityStorage() {
    try {
        localStorage.removeItem("kumpir_player_id");
        sessionStorage.removeItem("kumpir_player_id");
        localStorage.removeItem("kumpir_player_name");
        sessionStorage.removeItem("kumpir_player_name");
    } catch {}
}

const GAME_PHASES = new Set(["topic_vote", "countdown", "running"]);

export default function LobbyPage() {
    const params = useParams<{ code: string }>();
    const router = useRouter();

    const code = String(params.code ?? "").toUpperCase();
    const { mePlayerId, meName } = usePlayerIdentity();

    const suppressRedirectRef = useRef(false);

    const go = useCallback(
        (url: string) => {
            router.replace(url);
        },
        [router]
    );

    const hardGoGame = useCallback(() => {
        go(`/game/${encodeURIComponent(code)}?t=${Date.now()}`);
    }, [code, go]);

    const { lobby, players, loading, error } = useLobbyState(code, { pollMs: 900 });

    const lobbyId = lobby?.id ?? null;

    const amIHost = useMemo(() => {
        if (!mePlayerId || !lobby?.host_player_id) return false;
        return lobby.host_player_id === mePlayerId;
    }, [lobby?.host_player_id, mePlayerId]);

    const isRunning = lobby?.phase === "running";

    useHeartbeat({
        lobbyId,
        playerId: mePlayerId,
        intervalMs: 8000,
        doCleanup: amIHost,
        staleSeconds: 25,
    });

    // Realtime: faster updates than 900ms polling (additive)
    useLobbyRealtime(lobbyId, () => {
        // Polling effect picks the change up on its next tick.
    });

    // ✅ game phases -> game
    useEffect(() => {
        if (suppressRedirectRef.current) return;
        const ph = lobby?.phase ?? null;
        if (ph && GAME_PHASES.has(ph)) hardGoGame();
    }, [lobby?.phase, hardGoGame]);

    // removed from lobby -> go /host with reason
    useEffect(() => {
        if (!mePlayerId) return;
        if (!lobbyId) return;
        if (loading) return;

        const stillInLobby = players.some((p) => p.player_id === mePlayerId);
        if (stillInLobby) return;

        (async () => {
            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                const { data, error: statusErr } = await supabase
                    .from("players")
                    .select("status")
                    .eq("lobby_id", lobbyId)
                    .eq("player_id", mePlayerId)
                    .maybeSingle();

                const status = !statusErr ? (data?.status as string | undefined) : undefined;

                clearMyIdentityStorage();
                suppressRedirectRef.current = true;

                go(status === "kicked" ? `/host?kicked=1` : `/host?left=1`);
            } catch {
                clearMyIdentityStorage();
                suppressRedirectRef.current = true;
                go(`/host`);
            }
        })();
    }, [loading, players, mePlayerId, lobbyId, go]);

    const [toast, setToast] = useState("");
    const [busyReady, setBusyReady] = useState(false);
    const [starting, setStarting] = useState(false);

    const showToast = useCallback((msg: string, ms = 1800) => {
        setToast(msg);
        window.setTimeout(() => setToast(""), ms);
    }, []);

    const copyInviteByClick = useCallback(async () => {
        try {
            const origin = window.location.origin;
            const link = fmtJoinLink(origin, code);
            await navigator.clipboard.writeText(link);
            showToast("✅ Link kopiert", 1200);
        } catch {
            showToast("⚠️ Kopieren nicht möglich", 1600);
        }
    }, [code, showToast]);

    const meReady = useMemo(() => {
        if (!mePlayerId) return false;
        const row = players.find((p) => p.player_id === mePlayerId);
        return !!row?.ready;
    }, [players, mePlayerId]);

    const MIN_PLAYERS = 2;
    const allReady = useMemo(() => {
        return players.length >= MIN_PLAYERS && players.every((p) => !!p.ready);
    }, [players]);

    const toggleReady = useCallback(async () => {
        if (!mePlayerId) return;
        if (!lobbyId) return;
        if (busyReady || starting || isRunning) return;

        setBusyReady(true);
        try {
            const { getSupabaseClient } = await import("@/lib/supabaseClient");
            const supabase = getSupabaseClient();

            const { error: rpcErr } = await supabase.rpc("rpc_toggle_ready", {
                p_lobby_id: lobbyId,
                p_player_id: mePlayerId,
            });

            if (rpcErr) showToast(`❌ ${rpcErr.message}`, 2500);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2500);
        } finally {
            setBusyReady(false);
        }
    }, [busyReady, starting, isRunning, lobbyId, mePlayerId, showToast]);

    const startGameClick = useCallback(async () => {
        if (!amIHost) return;
        if (!mePlayerId) return;
        if (starting || isRunning) return;

        setStarting(true);
        try {
            const res: StartGameResult = await startGame(code, mePlayerId);

            if (!res.ok) {
                const msg = "error" in res ? res.error : "Start fehlgeschlagen";
                showToast(`❌ ${msg}`, 2500);
                return;
            }

            // ✅ No immediate navigation; DB phase triggers redirect
            showToast("✅ Spiel startet…", 900);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2500);
        } finally {
            setStarting(false);
        }
    }, [amIHost, mePlayerId, starting, isRunning, code, showToast]);

    const leaveLobby = useCallback(async () => {
        suppressRedirectRef.current = true;

        try {
            // Optional: falls ihr später eine echte RPC habt (rpc_leave_lobby), hier einsetzen.
            // Aktuell nur best-effort: Spielerstatus auf left setzen (wenn RLS das erlaubt).
            if (mePlayerId && lobbyId) {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                await supabase.from("players").update({ status: "left" }).eq("lobby_id", lobbyId).eq("player_id", mePlayerId);
            }
        } catch {
            // ignore
        } finally {
            clearMyIdentityStorage();
            go("/host?left=1");
        }
    }, [mePlayerId, lobbyId, go]);

    const meLabel = useMemo(() => {
        return amIHost ? "👑 Host" : meName ? `👤 ${meName}` : "👤 Spieler";
    }, [amIHost, meName]);

    const maxPlayers = lobby?.max_players ?? 8;
    const mode = ((lobby?.game_mode ?? "original") as ModeKey) ?? "original";

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Lobby" style={{ position: "relative" }}>
                    <div
                        style={{
                            position: "sticky",
                            top: 0,
                            zIndex: 5,
                            paddingTop: 2,
                            paddingBottom: 10,
                            marginBottom: 6,
                            backdropFilter: "blur(10px)",
                            WebkitBackdropFilter: "blur(10px)",
                        }}
                    >
                        {isRunning ? (
                            <div className="pillChip" style={{ marginBottom: 10, fontWeight: 950, opacity: 0.95 }}>
                                🚀 Spiel läuft – Lobby ist read-only
                            </div>
                        ) : null}

                        <div style={{ display: "flex", justifyContent: "space-between", gap: 14, alignItems: "flex-start", flexWrap: "wrap" }}>
                            <div style={{ flex: 1, minWidth: 280 }}>
                                <h1 className="h1" style={{ marginBottom: 10 }}>
                                    Private Lobby
                                </h1>

                                <div style={{ display: "grid", placeItems: "center", marginTop: 6 }}>
                                    <button
                                        type="button"
                                        onClick={copyInviteByClick}
                                        title="Klick → Join-Link kopieren"
                                        style={{ border: "none", background: "transparent", cursor: isRunning ? "not-allowed" : "pointer", padding: 0 }}
                                        aria-label="Join-Link kopieren"
                                        disabled={isRunning}
                                    >
                                        <div
                                            style={{
                                                fontSize: 58,
                                                fontWeight: 950,
                                                letterSpacing: 6,
                                                lineHeight: 1,
                                                backgroundImage: "linear-gradient(90deg,#ff2d55,#ff9500,#ffd60a,#34c759,#0a84ff,#bf5af2,#ff2d55)",
                                                backgroundSize: "220% 100%",
                                                WebkitBackgroundClip: "text",
                                                backgroundClip: "text",
                                                color: "transparent",
                                                animation: "kumpir-rainbow 2.8s linear infinite",
                                                textShadow: "0 10px 30px rgba(0,0,0,0.18)",
                                                userSelect: "none",
                                                opacity: isRunning ? 0.75 : 1,
                                            }}
                                        >
                                            {code}
                                        </div>
                                    </button>

                                    {toast ? (
                                        <div className="fieldHelp" style={{ marginTop: 8, fontWeight: 900, opacity: 0.95, textAlign: "center" }}>
                                            {toast}
                                        </div>
                                    ) : (
                                        <div className="fieldHelp" style={{ marginTop: 8, opacity: 0.85, textAlign: "center" }}>
                                            Klick auf den Code kopiert den Join-Link.
                                        </div>
                                    )}

                                    <style>{`
                    @keyframes kumpir-rainbow {
                      0% { background-position: 0% 50%; }
                      100% { background-position: 100% 50%; }
                    }
                  `}</style>
                                </div>
                            </div>

                            <div style={{ display: "grid", gap: 10, justifyItems: "end", minWidth: 240 }}>
                                <div className="pillChip" style={{ height: 34, display: "flex", alignItems: "center", justifyContent: "center" }}>
                                    {meLabel}
                                </div>

                                <div style={{ display: "grid", gap: 8, justifyItems: "end" }}>
                                    <div className="pillChip" style={{ height: 32, display: "flex", alignItems: "center", gap: 8 }}>
                                        <span style={{ opacity: 0.8 }}>👥</span>
                                        <span style={{ fontWeight: 900 }}>{players.length}</span>
                                        <span style={{ opacity: 0.8 }}>/</span>
                                        <span style={{ fontWeight: 900 }}>{maxPlayers}</span>
                                    </div>

                                    <div className="pillChip" style={{ height: 32, display: "flex", alignItems: "center", gap: 8 }}>
                                        <span>{MODES[mode]?.icon ?? "🥔"}</span>
                                        <span style={{ fontWeight: 900 }}>{MODES[mode]?.label ?? mode}</span>
                                    </div>

                                    {lobby?.topic ? (
                                        <div className="pillChip" style={{ height: 32, display: "flex", alignItems: "center", gap: 8, maxWidth: 260 }} title={lobby.topic ?? undefined}>
                                            <span style={{ opacity: 0.8 }}>🏷️</span>
                                            <span style={{ fontWeight: 900, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                        {lobby.topic}
                      </span>
                                        </div>
                                    ) : null}
                                </div>

                                {amIHost ? (
                                    <Link
                                        href={`/lobby/${encodeURIComponent(code)}/admin`}
                                        className={`btn btnSecondary btnSmall ${starting || isRunning ? "btnDisabled" : ""}`}
                                        aria-disabled={starting || isRunning}
                                        tabIndex={starting || isRunning ? -1 : 0}
                                        onClick={(e) => {
                                            if (starting || isRunning) e.preventDefault();
                                        }}
                                        title="Admin Panel öffnen"
                                    >
                                        ⚙️ Admin
                                    </Link>
                                ) : null}
                            </div>
                        </div>
                    </div>

                    <div className="stepsWrap">
                        <div className="stepsBox">
                            <div className="stepsTitle">Spieler</div>
                            {error ? <p className="errorText">{error}</p> : null}

                            <div style={{ overflowX: "auto" }}>
                                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                                    <thead>
                                    <tr style={{ textAlign: "left", opacity: 0.75 }}>
                                        <th style={{ padding: "10px 8px" }}>#</th>
                                        <th style={{ padding: "10px 8px" }}>Name</th>
                                        <th style={{ padding: "10px 8px", textAlign: "right" }}>Zustand</th>
                                    </tr>
                                    </thead>

                                    <tbody>
                                    {loading && players.length === 0 ? (
                                        <tr>
                                            <td colSpan={3} style={{ padding: "12px 8px", opacity: 0.85 }}>
                                                <Spinner size={16} label="Lade Spieler…" />
                                            </td>
                                        </tr>
                                    ) : null}

                                    {players.map((p, idx) => {
                                        const isMe = !!mePlayerId && p.player_id === mePlayerId;
                                        const isHostRow = !!lobby?.host_player_id && p.player_id === lobby.host_player_id;

                                        return (
                                            <tr
                                                key={p.player_id}
                                                style={{
                                                    borderTop: "1px solid rgba(255,255,255,0.08)",
                                                    opacity: isMe ? 1 : 0.95,
                                                    background: isHostRow ? "rgba(255,255,255,0.07)" : "transparent",
                                                }}
                                            >
                                                <td style={{ padding: "10px 8px" }}>{idx + 1}</td>
                                                <td style={{ padding: "10px 8px", fontWeight: 900 }}>
                                                    {p.name} {isMe ? <span style={{ opacity: 0.6 }}>(du)</span> : null}
                                                    {isHostRow ? (
                                                        <span
                                                            style={{
                                                                marginLeft: 10,
                                                                fontWeight: 950,
                                                                opacity: 0.98,
                                                                padding: "4px 10px",
                                                                borderRadius: 999,
                                                                background: "rgba(255,255,255,0.08)",
                                                                border: "1px solid rgba(255,255,255,0.10)",
                                                            }}
                                                        >
                                👑 Host
                              </span>
                                                    ) : null}
                                                </td>

                                                <td style={{ padding: "10px 8px", textAlign: "right", fontWeight: 950 }}>{p.ready ? "✅ Bereit" : "⏳ nicht bereit"}</td>
                                            </tr>
                                        );
                                    })}

                                    {!loading && players.length === 0 ? (
                                        <tr>
                                            <td colSpan={3} style={{ padding: "12px 8px", opacity: 0.75 }}>
                                                Noch niemand beigetreten.
                                            </td>
                                        </tr>
                                    ) : null}
                                    </tbody>
                                </table>
                            </div>

                            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", gap: 12, marginTop: 14 }}>
                                <button type="button" className="btn btnSecondary btnSmall" onClick={() => void leaveLobby()} disabled={starting}>
                                    ← Hauptmenü
                                </button>

                                <button
                                    type="button"
                                    onClick={toggleReady}
                                    disabled={busyReady || !mePlayerId || starting || isRunning}
                                    className={`btn btnXL ${busyReady || starting || isRunning ? "btnDisabled" : ""} ${meReady ? "btnReadyOff" : "btnReadyOn"}`}
                                >
                                    {isRunning ? "🚀 Läuft" : starting ? "…" : busyReady ? "…" : meReady ? "⛔ Nicht bereit" : "✨ Bereit"}
                                </button>
                            </div>

                            {/* ✅ START BUTTON: Host + allReady */}
                            {amIHost && allReady && lobby?.phase !== "running" ? (
                                <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 10 }}>
                                    <button type="button" className="btn btnPrimary btnSmall btnGlow" onClick={() => void startGameClick()} disabled={starting || isRunning}>
                                        🚀 Spiel starten
                                    </button>
                                </div>
                            ) : null}

                            {!allReady ? (
                                <div style={{ marginTop: 10, opacity: 0.75, fontWeight: 800, fontSize: 13 }}>
                                    Mindestens {MIN_PLAYERS} Spieler müssen beitreten und bereit sein.
                                </div>
                            ) : null}
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}