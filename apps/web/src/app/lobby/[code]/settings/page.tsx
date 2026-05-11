"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";
import { getSupabaseClient } from "@/lib/supabaseClient";

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

export default function LobbySettingsPage() {
    const params = useParams<{ code: string }>();
    const router = useRouter();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId } = usePlayerIdentity();
    const { lobby, players, loading, error } = useLobbyState(code, { pollMs: 900 });

    const amIHost = useMemo(() => {
        if (!mePlayerId || !lobby?.host_player_id) return false;
        return lobby.host_player_id === mePlayerId;
    }, [lobby?.host_player_id, mePlayerId]);

    // host-only guard
    useEffect(() => {
        if (loading) return;
        if (!lobby) return;
        if (!mePlayerId) return;
        if (!amIHost) router.replace(`/lobby/${encodeURIComponent(code)}`);
    }, [loading, lobby, mePlayerId, amIHost, router, code]);

    const maxPlayers = lobby?.max_players ?? 8;
    const mode = ((lobby?.game_mode ?? "original") as ModeKey) ?? "original";

    const [busy, setBusy] = useState(false);
    const [toast, setToast] = useState("");

    const [topicDraft, setTopicDraft] = useState("");

    useEffect(() => {
        setTopicDraft(lobby?.topic ?? "");
    }, [lobby?.topic]);

    const showToast = useCallback((msg: string, ms = 1600) => {
        setToast(msg);
        window.setTimeout(() => setToast(""), ms);
    }, []);

    const setMaxPlayers = useCallback(
        async (next: number) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobby?.id) return;
            if (busy) return;

            setBusy(true);
            try {
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("set_max_players", {
                    p_lobby_id: lobby.id,
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
        [amIHost, mePlayerId, lobby?.id, busy, showToast]
    );

    const setMode = useCallback(
        async (next: ModeKey) => {
            if (!amIHost) return;
            if (!mePlayerId || !lobby?.id) return;
            if (busy) return;

            setBusy(true);
            try {
                const supabase = getSupabaseClient();

                const { error: rpcErr } = await supabase.rpc("set_lobby_mode", {
                    p_lobby_id: lobby.id,
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
        [amIHost, mePlayerId, lobby?.id, busy, showToast]
    );

    const saveTopic = useCallback(async () => {
        if (!amIHost) return;
        if (!mePlayerId || !lobby?.id) return;
        if (busy) return;

        setBusy(true);
        try {
            const supabase = getSupabaseClient();

            const { error: rpcErr } = await supabase.rpc("set_lobby_topic", {
                p_lobby_id: lobby.id,
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
    }, [amIHost, mePlayerId, lobby?.id, busy, topicDraft, showToast]);

    const activeCount = players.length;

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Lobby Einstellungen">
                    <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "center" }}>
                        <div>
                            <h1 className="h1" style={{ marginBottom: 6 }}>
                                ⚙️ Lobby Einstellungen
                            </h1>
                            <div className="fieldHelp" style={{ opacity: 0.85 }}>
                                Code: <span style={{ fontWeight: 950 }}>{code}</span>
                            </div>
                        </div>

                        <button
                            type="button"
                            className="btn btnSecondary btnSmall"
                            onClick={() => router.push(`/lobby/${encodeURIComponent(code)}`)}
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

                    {/* Max Players */}
                    <div className="pillCard" style={{ marginTop: 14 }}>
                        <div className="pillCardTop">
                            <div className="pillCardTitle">Max. Spieler</div>
                            <div className="pillCardHint">Aktiv: {activeCount}</div>
                        </div>

                        <div style={{ display: "flex", gap: 10, alignItems: "center", justifyContent: "space-between", marginTop: 10 }}>
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
                                {maxPlayers}
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
                    <div className="pillCard" style={{ marginTop: 14 }}>
                        <div className="pillCardTop">
                            <div className="pillCardTitle">Modus</div>
                            <div className="pillCardHint">Regeln für die Runde</div>
                        </div>

                        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 10 }}>
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
                    <div className="pillCard" style={{ marginTop: 14 }}>
                        <div className="pillCardTop">
                            <div className="pillCardTitle">Thema</div>
                            <div className="pillCardHint">Optional (max 60)</div>
                        </div>

                        <div style={{ display: "flex", gap: 10, alignItems: "center", marginTop: 10 }}>
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

                    <div className="fieldHelp" style={{ marginTop: 14, opacity: 0.8 }}>
                        Hinweis: Nur der Host kann diese Seite sehen.
                    </div>
                </section>
            </div>
        </main>
    );
}
