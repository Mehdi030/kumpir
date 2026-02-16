"use client";

import { startGame, type StartGameResult } from "@/actions/startGame";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";

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

export default function LobbyPage() {
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId, meName } = usePlayerIdentity();

    // blocks redirect when user intentionally leaves
    const suppressRunningRedirectRef = useRef(false);

    // prevents multi-redirect spam / loops
    const redirectingRef = useRef(false);

    const hardGoGame = useCallback(() => {
        if (typeof window === "undefined") return;
        if (redirectingRef.current) return;
        redirectingRef.current = true;

        // cache-buster helps when a device "sticks" on old state
        const url = `/game/${encodeURIComponent(code)}?t=${Date.now()}`;
        window.location.assign(url);
    }, [code]);

    const { lobby, players, loading, error } = useLobbyState(code, {
        pollMs: 900,
        onPhaseRunning: () => {
            if (suppressRunningRedirectRef.current) return;
            hardGoGame();
        },
    });

    // fallback redirect
    useEffect(() => {
        if (suppressRunningRedirectRef.current) return;
        if (lobby?.phase === "running") hardGoGame();
    }, [lobby?.phase, hardGoGame]);

    const [toast, setToast] = useState("");
    const [busyReady, setBusyReady] = useState(false);
    const [starting, setStarting] = useState(false);

    // host action busy flags
    const [busyLock, setBusyLock] = useState(false);
    const [busyKickId, setBusyKickId] = useState<string | null>(null);
    const [busyTransferId, setBusyTransferId] = useState<string | null>(null);

    const amIHost = useMemo(() => {
        if (!mePlayerId || !lobby?.host_player_id) return false;
        return lobby.host_player_id === mePlayerId;
    }, [lobby?.host_player_id, mePlayerId]);

    const locked = !!lobby?.locked;

    const meReady = useMemo(() => {
        if (!mePlayerId) return false;
        const row = players.find((p) => p.player_id === mePlayerId);
        return !!row?.ready;
    }, [players, mePlayerId]);

    const MIN_PLAYERS = 2;

    const allReady = useMemo(() => {
        return players.length >= MIN_PLAYERS && players.every((p) => !!p.ready);
    }, [players]);

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

    const toggleReady = useCallback(async () => {
        if (!mePlayerId) return;
        if (!lobby?.id) return;
        if (busyReady || starting || locked) return;

        setBusyReady(true);
        try {
            const { getSupabaseClient } = await import("@/lib/supabaseClient");
            const supabase = getSupabaseClient();

            const { error: rpcErr } = await supabase.rpc("rpc_toggle_ready", {
                p_lobby_id: lobby.id,
                p_player_id: mePlayerId,
            });

            if (rpcErr) showToast(`❌ ${rpcErr.message}`, 2500);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2500);
        } finally {
            setBusyReady(false);
        }
    }, [busyReady, starting, locked, lobby?.id, mePlayerId, showToast]);

    const startGameClick = useCallback(async () => {
        if (!amIHost) return;
        if (!mePlayerId) return;
        if (starting) return;

        setStarting(true);
        try {
            const res: StartGameResult = await startGame(code, mePlayerId);

            if (!res.ok) {
                const msg = "error" in res ? res.error : "Start fehlgeschlagen";
                showToast(`❌ ${msg}`, 2500);
                return;
            }

            showToast("✅ Spiel startet…", 900);
            hardGoGame();
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2500);
        } finally {
            setStarting(false);
        }
    }, [amIHost, mePlayerId, starting, code, showToast, hardGoGame]);

    const leaveLobby = useCallback(() => {
        suppressRunningRedirectRef.current = true;
        if (typeof window !== "undefined") window.location.assign("/host");
    }, []);

    const meLabel = useMemo(() => {
        return amIHost ? "👑 Host" : meName ? `👤 ${meName}` : "👤 Spieler";
    }, [amIHost, meName]);

    const toggleLobbyLock = useCallback(async () => {
        if (!amIHost) return;
        if (!mePlayerId || !lobby?.id) return;
        if (busyLock || starting) return;

        setBusyLock(true);
        try {
            const { getSupabaseClient } = await import("@/lib/supabaseClient");
            const supabase = getSupabaseClient();

            const next = !locked;

            const { error: rpcErr } = await supabase.rpc("set_lobby_lock", {
                p_lobby_id: lobby.id,
                p_me_player_id: mePlayerId,
                p_locked: next,
            });

            if (rpcErr) {
                showToast(`❌ ${rpcErr.message}`, 2500);
                return;
            }

            showToast(next ? "🔒 Lobby gesperrt" : "🔓 Lobby offen", 1400);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2500);
        } finally {
            setBusyLock(false);
        }
    }, [amIHost, busyLock, starting, lobby?.id, locked, mePlayerId, showToast]);

    const kickPlayer = useCallback(
        async (targetPlayerId: string) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobby?.id) return;
            if (busyKickId || starting) return;

            if (targetPlayerId === lobby.host_player_id) return;

            setBusyKickId(targetPlayerId);
            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("kick_player", {
                    p_lobby_id: lobby.id,
                    p_me_player_id: mePlayerId,
                    p_target_player_id: targetPlayerId,
                });

                if (rpcErr) {
                    showToast(`❌ ${rpcErr.message}`, 2500);
                    return;
                }

                showToast("✅ Spieler gekickt", 1400);
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2500);
            } finally {
                setBusyKickId(null);
            }
        },
        [amIHost, busyKickId, starting, lobby?.id, lobby?.host_player_id, mePlayerId, showToast]
    );

    const makeHost = useCallback(
        async (newHostPlayerId: string) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobby?.id) return;
            if (busyTransferId || starting) return;

            if (newHostPlayerId === lobby.host_player_id) return;

            setBusyTransferId(newHostPlayerId);
            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("transfer_host", {
                    p_lobby_id: lobby.id,
                    p_me_player_id: mePlayerId,
                    p_new_host_player_id: newHostPlayerId,
                });

                if (rpcErr) {
                    showToast(`❌ ${rpcErr.message}`, 2500);
                    return;
                }

                showToast("👑 Host übertragen", 1400);
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2500);
            } finally {
                setBusyTransferId(null);
            }
        },
        [amIHost, busyTransferId, starting, lobby?.id, lobby?.host_player_id, mePlayerId, showToast]
    );

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Lobby" style={{ position: "relative" }}>
                    <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "flex-start" }}>
                        <div style={{ flex: 1 }}>
                            <h1 className="h1" style={{ marginBottom: 10 }}>
                                Private Lobby
                            </h1>

                            <div style={{ display: "grid", placeItems: "center", marginTop: 6 }}>
                                <button
                                    type="button"
                                    onClick={copyInviteByClick}
                                    title="Klick → Join-Link kopieren"
                                    style={{ border: "none", background: "transparent", cursor: "pointer", padding: 0 }}
                                    aria-label="Join-Link kopieren"
                                >
                                    <div
                                        style={{
                                            fontSize: 58,
                                            fontWeight: 950,
                                            letterSpacing: 6,
                                            lineHeight: 1,
                                            backgroundImage:
                                                "linear-gradient(90deg,#ff2d55,#ff9500,#ffd60a,#34c759,#0a84ff,#bf5af2,#ff2d55)",
                                            backgroundSize: "220% 100%",
                                            WebkitBackgroundClip: "text",
                                            backgroundClip: "text",
                                            color: "transparent",
                                            animation: "kumpir-rainbow 2.8s linear infinite",
                                            textShadow: "0 10px 30px rgba(0,0,0,0.18)",
                                            userSelect: "none",
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

                        <div style={{ display: "grid", gap: 8, justifyItems: "end" }}>
                            <div className="pillChip" style={{ height: 34, display: "flex", alignItems: "center" }}>
                                {meLabel}
                            </div>

                            {amIHost ? (
                                <button
                                    type="button"
                                    className="btn btnSecondary btnSmall"
                                    onClick={() => void toggleLobbyLock()}
                                    disabled={busyLock || starting}
                                    title="Lobby sperren/entsperren"
                                >
                                    {busyLock ? "…" : locked ? "🔒 Gesperrt" : "🔓 Offen"}
                                </button>
                            ) : null}
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
                                        {amIHost ? <th style={{ padding: "10px 8px", textAlign: "right" }}>Aktion</th> : null}
                                    </tr>
                                    </thead>

                                    <tbody>
                                    {loading && players.length === 0 ? (
                                        <tr>
                                            <td colSpan={amIHost ? 4 : 3} style={{ padding: "12px 8px", opacity: 0.75 }}>
                                                Lädt…
                                            </td>
                                        </tr>
                                    ) : null}

                                    {players.map((p, idx) => {
                                        const isMe = !!mePlayerId && p.player_id === mePlayerId;
                                        const isHostRow = !!lobby?.host_player_id && p.player_id === lobby.host_player_id;

                                        const canKick = amIHost && !isHostRow;
                                        const canMakeHost = amIHost && !isHostRow;

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

                                                <td style={{ padding: "10px 8px", textAlign: "right", fontWeight: 950 }}>
                                                    {p.ready ? "✅ Bereit" : "⏳ nicht bereit"}
                                                </td>

                                                {amIHost ? (
                                                    <td style={{ padding: "10px 8px", textAlign: "right" }}>
                                                        <div style={{ display: "inline-flex", gap: 8, justifyContent: "flex-end" }}>
                                                            {canMakeHost ? (
                                                                <button
                                                                    type="button"
                                                                    className="btn btnSecondary btnSmall"
                                                                    onClick={() => void makeHost(p.player_id)}
                                                                    disabled={!!busyTransferId || starting}
                                                                    title="Host übertragen"
                                                                >
                                                                    {busyTransferId === p.player_id ? "…" : "👑"}
                                                                </button>
                                                            ) : null}

                                                            {canKick ? (
                                                                <button
                                                                    type="button"
                                                                    className="btn btnSecondary btnSmall"
                                                                    onClick={() => void kickPlayer(p.player_id)}
                                                                    disabled={!!busyKickId || starting}
                                                                    title="Kick (nur waiting)"
                                                                >
                                                                    {busyKickId === p.player_id ? "…" : "⛔"}
                                                                </button>
                                                            ) : null}
                                                        </div>
                                                    </td>
                                                ) : null}
                                            </tr>
                                        );
                                    })}

                                    {!loading && players.length === 0 ? (
                                        <tr>
                                            <td colSpan={amIHost ? 4 : 3} style={{ padding: "12px 8px", opacity: 0.75 }}>
                                                Noch niemand beigetreten.
                                            </td>
                                        </tr>
                                    ) : null}
                                    </tbody>
                                </table>
                            </div>

                            {/* ✅ Buttons row */}
                            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", gap: 12, marginTop: 14 }}>
                                <button type="button" className="btn btnSecondary btnSmall" onClick={leaveLobby} disabled={starting}>
                                    ← Neue Lobby
                                </button>

                                <button
                                    type="button"
                                    onClick={toggleReady}
                                    disabled={busyReady || !mePlayerId || starting || locked}
                                    className={`btn btnXL ${busyReady || starting || locked ? "btnDisabled" : ""} ${meReady ? "btnReadyOff" : "btnReadyOn"}`}
                                >
                                    {locked ? "🔒 Gesperrt" : starting ? "…" : busyReady ? "…" : meReady ? "⛔ Nicht bereit" : "✨ Bereit"}
                                </button>
                            </div>

                            {/* ✅ Start button below (not inside the row) */}
                            {amIHost && allReady && lobby?.phase !== "running" ? (
                                <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 10 }}>
                                    <button type="button" className="btn btnPrimary btnSmall btnGlow" onClick={() => void startGameClick()} disabled={starting}>
                                        🚀 Spiel starten
                                    </button>
                                </div>
                            ) : null}

                            {!allReady ? (
                                <div style={{ marginTop: 10, opacity: 0.75, fontWeight: 800, fontSize: 13 }}>
                                    Mindestens {MIN_PLAYERS} Spieler müssen beitreten und bereit sein.
                                </div>
                            ) : null}

                            {amIHost && locked ? (
                                <div style={{ marginTop: 10, opacity: 0.82, fontWeight: 850, fontSize: 13 }}>
                                    🔒 Lobby ist gesperrt — niemand kann neu beitreten.
                                </div>
                            ) : null}
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}