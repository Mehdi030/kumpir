"use client";

import { startGame, type StartGameResult } from "@/actions/startGame";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";
import { useHeartbeat } from "@/hooks/useHeartbeat";

type ModeKey = "original" | "teleport" | "reverse";

const MODES: Record<ModeKey, { label: string; icon: string; disabled?: boolean; comingSoon?: boolean }> = {
    original: { label: "Original", icon: "🥔" },
    teleport: { label: "Teleport", icon: "🌀", disabled: true, comingSoon: true },
    reverse: { label: "Reverse", icon: "🔁", disabled: true, comingSoon: true },
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

export default function LobbyPage() {
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId, meName } = usePlayerIdentity();

    const suppressRunningRedirectRef = useRef(false);
    const redirectingRef = useRef(false);

    const safeRedirect = useCallback((url: string) => {
        if (typeof window === "undefined") return;
        if (redirectingRef.current) return;
        redirectingRef.current = true;
        window.location.assign(url);
    }, []);

    const hardGoGame = useCallback(() => {
        safeRedirect(`/game/${encodeURIComponent(code)}?t=${Date.now()}`);
    }, [code, safeRedirect]);

    const { lobby, players, loading, error } = useLobbyState(code, {
        pollMs: 900,
        onPhaseRunning: () => {
            if (suppressRunningRedirectRef.current) return;
            hardGoGame();
        },
    });

    const lobbyId = lobby?.id ?? null;

    const amIHost = useMemo(() => {
        if (!mePlayerId || !lobby?.host_player_id) return false;
        return lobby.host_player_id === mePlayerId;
    }, [lobby?.host_player_id, mePlayerId]);

    // heartbeat + cleanup (host-only cleanup)
    useHeartbeat({
        lobbyId,
        playerId: mePlayerId,
        intervalMs: 8000,
        doCleanup: amIHost,
        staleSeconds: 25,
    });

    useEffect(() => {
        if (suppressRunningRedirectRef.current) return;
        if (lobby?.phase === "running") hardGoGame();
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
                suppressRunningRedirectRef.current = true;

                safeRedirect(status === "kicked" ? `/host?kicked=1` : `/host?left=1`);
            } catch {
                clearMyIdentityStorage();
                suppressRunningRedirectRef.current = true;
                safeRedirect(`/host`);
            }
        })();
    }, [loading, players, mePlayerId, lobbyId, safeRedirect]);

    const [toast, setToast] = useState("");
    const [busyReady, setBusyReady] = useState(false);
    const [starting, setStarting] = useState(false);

    const [busyKickId, setBusyKickId] = useState<string | null>(null);
    const [busyTransferId, setBusyTransferId] = useState<string | null>(null);

    // host settings busy
    const [busySettings, setBusySettings] = useState(false);

    // topic draft input
    const [topicDraft, setTopicDraft] = useState("");

    useEffect(() => {
        setTopicDraft(lobby?.topic ?? "");
    }, [lobby?.topic]);

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
        if (busyReady || starting) return;

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
    }, [busyReady, starting, lobbyId, mePlayerId, showToast]);

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

    const leaveLobby = useCallback(async () => {
        suppressRunningRedirectRef.current = true;

        try {
            if (mePlayerId && lobbyId) {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                await supabase.rpc("leave_lobby", {
                    p_lobby_id: lobbyId,
                    p_player_id: mePlayerId,
                });
            }
        } catch {
            // ignore
        } finally {
            clearMyIdentityStorage();
            safeRedirect("/host?left=1");
        }
    }, [mePlayerId, lobbyId, safeRedirect]);

    const meLabel = useMemo(() => {
        return amIHost ? "👑 Host" : meName ? `👤 ${meName}` : "👤 Spieler";
    }, [amIHost, meName]);

    // Host: set max players
    const setMaxPlayers = useCallback(
        async (next: number) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobbyId) return;
            if (busySettings || starting) return;

            setBusySettings(true);
            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("set_max_players", {
                    p_lobby_id: lobbyId,
                    p_me_player_id: mePlayerId,
                    p_max_players: next,
                });

                if (rpcErr) {
                    const msg = rpcErr.message === "too_small_for_current_players" ? "Zu klein für aktuelle Spielerzahl." : rpcErr.message;
                    showToast(`❌ ${msg}`, 2500);
                    return;
                }

                showToast("✅ Max-Spieler aktualisiert", 1200);
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2500);
            } finally {
                setBusySettings(false);
            }
        },
        [amIHost, mePlayerId, lobbyId, busySettings, starting, showToast]
    );

    // Host: set mode
    const setMode = useCallback(
        async (mode: ModeKey) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobbyId) return;
            if (busySettings || starting) return;

            setBusySettings(true);
            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("set_lobby_mode", {
                    p_lobby_id: lobbyId,
                    p_me_player_id: mePlayerId,
                    p_mode: mode,
                });

                if (rpcErr) {
                    showToast(`❌ ${rpcErr.message}`, 2500);
                    return;
                }

                showToast("✅ Modus aktualisiert", 1200);
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2500);
            } finally {
                setBusySettings(false);
            }
        },
        [amIHost, mePlayerId, lobbyId, busySettings, starting, showToast]
    );

    // Host: set topic
    const saveTopic = useCallback(async () => {
        if (!amIHost) return;
        if (!mePlayerId || !lobbyId) return;
        if (busySettings || starting) return;

        setBusySettings(true);
        try {
            const { getSupabaseClient } = await import("@/lib/supabaseClient");
            const supabase = getSupabaseClient();

            const { error: rpcErr } = await supabase.rpc("set_lobby_topic", {
                p_lobby_id: lobbyId,
                p_me_player_id: mePlayerId,
                p_topic: topicDraft,
            });

            if (rpcErr) {
                const msg = rpcErr.message === "topic_too_long" ? "Thema ist zu lang (max 60)." : rpcErr.message;
                showToast(`❌ ${msg}`, 2500);
                return;
            }

            showToast("✅ Thema gespeichert", 1200);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2500);
        } finally {
            setBusySettings(false);
        }
    }, [amIHost, mePlayerId, lobbyId, busySettings, starting, topicDraft, showToast]);

    const kickPlayer = useCallback(
        async (targetPlayerId: string) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobbyId) return;
            if (busyKickId || starting) return;

            if (targetPlayerId === lobby?.host_player_id) return;

            setBusyKickId(targetPlayerId);
            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("kick_player", {
                    p_lobby_id: lobbyId,
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
        [amIHost, busyKickId, starting, lobbyId, lobby?.host_player_id, mePlayerId, showToast]
    );

    const makeHost = useCallback(
        async (newHostPlayerId: string) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobbyId) return;
            if (busyTransferId || starting) return;

            if (newHostPlayerId === lobby?.host_player_id) return;

            setBusyTransferId(newHostPlayerId);
            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("transfer_host", {
                    p_lobby_id: lobbyId,
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
        [amIHost, busyTransferId, starting, lobbyId, lobby?.host_player_id, mePlayerId, showToast]
    );

    const maxPlayers = lobby?.max_players ?? 8;
    const mode = ((lobby?.game_mode ?? "original") as ModeKey) ?? "original";

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

                        <div style={{ display: "grid", gap: 10, justifyItems: "end", minWidth: 260 }}>
                            <div className="pillChip" style={{ height: 34, display: "flex", alignItems: "center", justifyContent: "center" }}>
                                {meLabel}
                            </div>

                            {/* Settings summary (for all) */}
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
                                    <div className="pillChip" style={{ height: 32, display: "flex", alignItems: "center", gap: 8, maxWidth: 260 }}>
                                        <span style={{ opacity: 0.8 }}>🏷️</span>
                                        <span style={{ fontWeight: 900, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                      {lobby.topic}
                    </span>
                                    </div>
                                ) : null}
                            </div>

                            {/* Host controls */}
                            {amIHost ? (
                                <div style={{ display: "grid", gap: 10, justifyItems: "end" }}>
                                    <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                                        <button
                                            type="button"
                                            className="btn btnSecondary btnSmall"
                                            onClick={() => void setMaxPlayers(Math.max(2, maxPlayers - 1))}
                                            disabled={busySettings || starting || maxPlayers <= 2}
                                            title="Max-Spieler runter"
                                        >
                                            −
                                        </button>
                                        <div className="pillChip" style={{ height: 32, display: "flex", alignItems: "center" }}>
                                            Max {maxPlayers}
                                        </div>
                                        <button
                                            type="button"
                                            className="btn btnSecondary btnSmall"
                                            onClick={() => void setMaxPlayers(Math.min(12, maxPlayers + 1))}
                                            disabled={busySettings || starting || maxPlayers >= 12}
                                            title="Max-Spieler hoch"
                                        >
                                            +
                                        </button>
                                    </div>

                                    <div style={{ display: "flex", gap: 8, flexWrap: "wrap", justifyContent: "flex-end" }}>
                                        {(Object.keys(MODES) as ModeKey[]).map((k) => {
                                            const m = MODES[k];
                                            const active = mode === k;
                                            return (
                                                <button
                                                    key={k}
                                                    type="button"
                                                    className={`btn btnSecondary btnSmall ${active ? "btnGlow" : ""}`}
                                                    onClick={() => void setMode(k)}
                                                    disabled={busySettings || starting || !!m.disabled}
                                                    title={m.comingSoon ? "Kommt bald" : "Modus setzen"}
                                                >
                                                    {m.icon} {m.label}
                                                </button>
                                            );
                                        })}
                                    </div>

                                    <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                                        <input
                                            value={topicDraft}
                                            onChange={(e) => setTopicDraft(e.target.value)}
                                            placeholder="Thema (z.B. Filmzitate)"
                                            maxLength={60}
                                            className="pillInput"
                                            style={{ width: 180 }}
                                            aria-label="Thema"
                                        />
                                        <button
                                            type="button"
                                            className="btn btnPrimary btnSmall"
                                            onClick={() => void saveTopic()}
                                            disabled={busySettings || starting}
                                            title="Thema speichern"
                                        >
                                            💾
                                        </button>
                                    </div>
                                </div>
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
                                                                    title="Kick"
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

                            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", gap: 12, marginTop: 14 }}>
                                <button type="button" className="btn btnSecondary btnSmall" onClick={() => void leaveLobby()} disabled={starting}>
                                    ← Hauptmenü
                                </button>

                                <button
                                    type="button"
                                    onClick={toggleReady}
                                    disabled={busyReady || !mePlayerId || starting}
                                    className={`btn btnXL ${busyReady || starting ? "btnDisabled" : ""} ${meReady ? "btnReadyOff" : "btnReadyOn"}`}
                                >
                                    {starting ? "…" : busyReady ? "…" : meReady ? "⛔ Nicht bereit" : "✨ Bereit"}
                                </button>
                            </div>

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
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}