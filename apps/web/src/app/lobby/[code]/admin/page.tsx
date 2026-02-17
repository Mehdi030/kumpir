"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useParams } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";

type ModeKey = "original" | "teleport" | "reverse";

const MODES: Record<ModeKey, { label: string; icon: string; disabled?: boolean; comingSoon?: boolean }> = {
    original: { label: "Original", icon: "🥔" },
    teleport: { label: "Teleport", icon: "🌀", disabled: true, comingSoon: true },
    reverse: { label: "Reverse", icon: "🔁", disabled: true, comingSoon: true },
};

function getErrorMessage(e: unknown): string {
    if (e instanceof Error) return e.message;
    if (typeof e === "string") return e;
    try {
        return JSON.stringify(e);
    } catch {
        return "Unbekannter Fehler";
    }
}

export default function LobbyAdminPage() {
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId } = usePlayerIdentity();
    const { lobby, players, loading, error } = useLobbyState(code, { pollMs: 900 });

    const lobbyId = lobby?.id ?? null;

    const amIHost = useMemo(() => {
        if (!mePlayerId || !lobby?.host_player_id) return false;
        return lobby.host_player_id === mePlayerId;
    }, [lobby?.host_player_id, mePlayerId]);

    // hard guard
    useEffect(() => {
        if (loading) return;
        if (!lobbyId) return;
        if (!mePlayerId) return;
        if (amIHost) return;
        window.location.assign(`/lobby/${encodeURIComponent(code)}`);
    }, [loading, lobbyId, mePlayerId, amIHost, code]);

    const [toast, setToast] = useState("");
    const [busy, setBusy] = useState(false);

    const showToast = useCallback((msg: string, ms = 1600) => {
        setToast(msg);
        window.setTimeout(() => setToast(""), ms);
    }, []);

    // settings state
    const maxPlayers = lobby?.max_players ?? 8;
    const mode = ((lobby?.game_mode ?? "original") as ModeKey) ?? "original";

    const [topicDraft, setTopicDraft] = useState("");
    useEffect(() => {
        setTopicDraft(lobby?.topic ?? "");
    }, [lobby?.topic]);

    const setMaxPlayers = useCallback(
        async (next: number) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobbyId) return;
            if (busy) return;

            setBusy(true);
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
                    showToast(`❌ ${msg}`, 2400);
                    return;
                }

                showToast("✅ Max-Spieler gespeichert");
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2400);
            } finally {
                setBusy(false);
            }
        },
        [amIHost, mePlayerId, lobbyId, busy, showToast]
    );

    const setMode = useCallback(
        async (next: ModeKey) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobbyId) return;
            if (busy) return;

            setBusy(true);
            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("set_lobby_mode", {
                    p_lobby_id: lobbyId,
                    p_me_player_id: mePlayerId,
                    p_mode: next,
                });

                if (rpcErr) {
                    showToast(`❌ ${rpcErr.message}`, 2400);
                    return;
                }

                showToast("✅ Modus gespeichert");
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2400);
            } finally {
                setBusy(false);
            }
        },
        [amIHost, mePlayerId, lobbyId, busy, showToast]
    );

    const saveTopic = useCallback(async () => {
        if (!amIHost) return;
        if (!mePlayerId || !lobbyId) return;
        if (busy) return;

        setBusy(true);
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
                showToast(`❌ ${msg}`, 2400);
                return;
            }

            showToast("✅ Thema gespeichert");
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2400);
        } finally {
            setBusy(false);
        }
    }, [amIHost, mePlayerId, lobbyId, busy, topicDraft, showToast]);

    // admin actions
    const [busyKickId, setBusyKickId] = useState<string | null>(null);
    const [busyTransferId, setBusyTransferId] = useState<string | null>(null);

    const kickPlayer = useCallback(
        async (targetPlayerId: string) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobbyId) return;
            if (busy || busyKickId) return;
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
                    showToast(`❌ ${rpcErr.message}`, 2400);
                    return;
                }

                showToast("✅ Spieler gekickt");
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2400);
            } finally {
                setBusyKickId(null);
            }
        },
        [amIHost, mePlayerId, lobbyId, busy, busyKickId, lobby?.host_player_id, showToast]
    );

    const makeHost = useCallback(
        async (newHostPlayerId: string) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobbyId) return;
            if (busy || busyTransferId) return;
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
                    showToast(`❌ ${rpcErr.message}`, 2400);
                    return;
                }

                showToast("👑 Host übertragen");
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2400);
            } finally {
                setBusyTransferId(null);
            }
        },
        [amIHost, mePlayerId, lobbyId, busy, busyTransferId, lobby?.host_player_id, showToast]
    );

    const activeCount = players.length;

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Lobby Admin">
                    <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "center" }}>
                        <div>
                            <h1 className="h1" style={{ marginBottom: 6 }}>
                                ⚙️ Lobby Admin
                            </h1>
                            <div className="fieldHelp" style={{ opacity: 0.85 }}>
                                Code: <span style={{ fontWeight: 950 }}>{code}</span>
                            </div>
                        </div>

                        <button
                            type="button"
                            className="btn btnSecondary btnSmall"
                            onClick={() => window.location.assign(`/lobby/${encodeURIComponent(code)}`)}
                            disabled={busy}
                        >
                            ← Zur Lobby
                        </button>
                    </div>

                    {error ? <p className="errorText" style={{ marginTop: 10 }}>{error}</p> : null}

                    {toast ? (
                        <div className="pillChip" style={{ marginTop: 12, fontWeight: 950, opacity: 0.96 }}>
                            {toast}
                        </div>
                    ) : null}

                    <div className="divider" style={{ marginTop: 14 }} />

                    {/* SETTINGS */}
                    <div className="pillCard" style={{ marginTop: 14 }}>
                        <div className="pillCardTop">
                            <div className="pillCardTitle">Einstellungen</div>
                            <div className="pillCardHint">Nur Host</div>
                        </div>

                        {/* Max players */}
                        <div style={{ marginTop: 12 }}>
                            <div className="fieldHelp" style={{ opacity: 0.85 }}>
                                👥 Aktiv: <span style={{ fontWeight: 950 }}>{activeCount}</span>
                            </div>

                            <div style={{ display: "flex", gap: 10, alignItems: "center", justifyContent: "space-between", marginTop: 8 }}>
                                <button
                                    type="button"
                                    className="btn btnSecondary btnSmall"
                                    onClick={() => void setMaxPlayers(Math.max(2, maxPlayers - 1))}
                                    disabled={busy || maxPlayers <= 2 || maxPlayers - 1 < activeCount}
                                    title={maxPlayers - 1 < activeCount ? "Zu klein für aktive Spieler" : "Verringern"}
                                >
                                    −
                                </button>

                                <div className="pillChip" style={{ height: 34, display: "flex", alignItems: "center" }}>
                                    Max {maxPlayers}
                                </div>

                                <button
                                    type="button"
                                    className="btn btnSecondary btnSmall"
                                    onClick={() => void setMaxPlayers(Math.min(12, maxPlayers + 1))}
                                    disabled={busy || maxPlayers >= 12}
                                    title="Erhöhen"
                                >
                                    +
                                </button>
                            </div>
                        </div>

                        {/* Mode */}
                        <div style={{ marginTop: 14 }}>
                            <div className="fieldHelp" style={{ opacity: 0.85 }}>
                                🥔 Modus aktuell: <span style={{ fontWeight: 950 }}>{MODES[mode]?.label ?? mode}</span>
                            </div>

                            <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 8 }}>
                                {(Object.keys(MODES) as ModeKey[]).map((k) => {
                                    const m = MODES[k];
                                    const active = mode === k;
                                    return (
                                        <button
                                            key={k}
                                            type="button"
                                            className={`btn btnSecondary btnSmall ${active ? "btnGlow" : ""}`}
                                            onClick={() => void setMode(k)}
                                            disabled={busy || !!m.disabled}
                                            title={m.comingSoon ? "Kommt bald" : "Setzen"}
                                        >
                                            {m.icon} {m.label}
                                        </button>
                                    );
                                })}
                            </div>
                        </div>

                        {/* Topic */}
                        <div style={{ marginTop: 14 }}>
                            <div className="fieldHelp" style={{ opacity: 0.85 }}>🏷️ Thema (optional, max 60)</div>
                            <div style={{ display: "flex", gap: 10, alignItems: "center", marginTop: 8 }}>
                                <input
                                    value={topicDraft}
                                    onChange={(e) => setTopicDraft(e.target.value)}
                                    placeholder="z.B. Filmzitate"
                                    maxLength={60}
                                    className="pillInput"
                                    style={{ flex: 1 }}
                                />
                                <button type="button" className="btn btnPrimary btnSmall" onClick={() => void saveTopic()} disabled={busy}>
                                    💾 Speichern
                                </button>
                            </div>
                        </div>
                    </div>

                    {/* PLAYERS ADMIN */}
                    <div className="pillCard" style={{ marginTop: 14 }}>
                        <div className="pillCardTop">
                            <div className="pillCardTitle">Spieler verwalten</div>
                            <div className="pillCardHint">Kick / Host übertragen</div>
                        </div>

                        <div style={{ overflowX: "auto", marginTop: 10 }}>
                            <table style={{ width: "100%", borderCollapse: "collapse" }}>
                                <thead>
                                <tr style={{ textAlign: "left", opacity: 0.75 }}>
                                    <th style={{ padding: "10px 8px" }}>Name</th>
                                    <th style={{ padding: "10px 8px", textAlign: "right" }}>Aktion</th>
                                </tr>
                                </thead>
                                <tbody>
                                {players.map((p) => {
                                    const isHostRow = !!lobby?.host_player_id && p.player_id === lobby.host_player_id;
                                    return (
                                        <tr key={p.player_id} style={{ borderTop: "1px solid rgba(255,255,255,0.08)" }}>
                                            <td style={{ padding: "10px 8px", fontWeight: 900 }}>
                                                {p.name} {isHostRow ? <span style={{ opacity: 0.75 }}> (Host)</span> : null}
                                            </td>
                                            <td style={{ padding: "10px 8px", textAlign: "right" }}>
                                                <div style={{ display: "inline-flex", gap: 8, justifyContent: "flex-end" }}>
                                                    {!isHostRow ? (
                                                        <button
                                                            type="button"
                                                            className="btn btnSecondary btnSmall"
                                                            onClick={() => void makeHost(p.player_id)}
                                                            disabled={busy || !!busyTransferId}
                                                            title="Host übertragen"
                                                        >
                                                            {busyTransferId === p.player_id ? "…" : "👑"}
                                                        </button>
                                                    ) : null}

                                                    {!isHostRow ? (
                                                        <button
                                                            type="button"
                                                            className="btn btnSecondary btnSmall"
                                                            onClick={() => void kickPlayer(p.player_id)}
                                                            disabled={busy || !!busyKickId}
                                                            title="Kick"
                                                        >
                                                            {busyKickId === p.player_id ? "…" : "⛔"}
                                                        </button>
                                                    ) : null}
                                                </div>
                                            </td>
                                        </tr>
                                    );
                                })}
                                {!loading && players.length === 0 ? (
                                    <tr>
                                        <td colSpan={2} style={{ padding: "12px 8px", opacity: 0.75 }}>
                                            Keine aktiven Spieler.
                                        </td>
                                    </tr>
                                ) : null}
                                </tbody>
                            </table>
                        </div>
                    </div>

                    <div className="fieldHelp" style={{ marginTop: 14, opacity: 0.8 }}>
                        Tipp: Diese Seite ist bewusst “Admin-only”, damit Lobby clean bleibt.
                    </div>
                </section>
            </div>
        </main>
    );
}