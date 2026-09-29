"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState, useTransition } from "react";
import { useParams, useRouter } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";
import { useHeartbeat } from "@/hooks/useHeartbeat";
import { useToastStack } from "@/hooks/useToastStack";
import { ToastStack } from "@/components/ToastStack";
import { Spinner } from "@/components/Spinner";
import { kickPlayerAction, setLobbyLockAction, transferHostAction } from "@/actions/hostActions";
import { getSessionToken } from "@/lib/playerSession";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { MUSIC_PLAYLISTS, MUSIC_GENRE_KEYS } from "@/lib/musicGenres";

const GAME_PHASES = new Set(["topic_vote", "countdown", "running"]);

type ModeKey = "original" | "teleport" | "reverse";
const MODES: Record<ModeKey, { label: string; icon: string }> = {
    original: { label: "Original", icon: "🥔" },
    teleport: { label: "Teleport", icon: "🌀" },
    reverse: { label: "Reverse", icon: "🔁" },
};

type AnswerModeKey = "text" | "voice";
const ANSWER_MODES: Record<AnswerModeKey, { label: string; icon: string }> = {
    text: { label: "Schreiben", icon: "⌨️" },
    voice: { label: "Mündlich", icon: "🎤" },
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
    const router = useRouter();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId } = usePlayerIdentity();
    const { lobby, players, loading, error } = useLobbyState(code, { pollMs: 1200 });

    const lobbyId = lobby?.id ?? null;

    const amIHost = useMemo(() => {
        if (!mePlayerId || !lobby?.host_player_id) return false;
        return lobby.host_player_id === mePlayerId;
    }, [lobby?.host_player_id, mePlayerId]);

    const isLocked = !!lobby?.locked;

    useHeartbeat({
        lobbyId,
        playerId: mePlayerId,
        intervalMs: 8000,
        doCleanup: amIHost,
        staleSeconds: 45,
    });

    // Redirect non-hosts back to lobby
    useEffect(() => {
        if (loading) return;
        if (!lobby) return;
        if (!mePlayerId) return;
        if (!amIHost) router.replace(`/lobby/${encodeURIComponent(code)}`);
    }, [loading, lobby, mePlayerId, amIHost, router, code]);

    // Redirect to game when phase advances
    useEffect(() => {
        const ph = lobby?.phase ?? null;
        if (ph && GAME_PHASES.has(ph)) {
            router.replace(`/game/${encodeURIComponent(code)}?t=${Date.now()}`);
        }
    }, [lobby?.phase, code, router]);

    const { toasts, pushToast } = useToastStack({ maxVisible: 3 });
    const showToast = useCallback((msg: string, ms = 1800) => pushToast(msg, ms), [pushToast]);

    const [pending, startTransition] = useTransition();
    const [busyTarget, setBusyTarget] = useState<string | null>(null);

    const onKick = useCallback(
        (targetPlayerId: string, targetName: string) => {
            if (!mePlayerId || !lobbyId) return;
            if (!confirm(`${targetName} wirklich aus der Lobby kicken?`)) return;

            setBusyTarget(targetPlayerId);
            startTransition(async () => {
                try {
                    const res = await kickPlayerAction({ lobbyId, mePlayerId, targetPlayerId, sessionToken: getSessionToken() ?? "" });
                    if (res.ok) {
                        showToast(`👢 ${targetName} gekickt`, 1400);
                    } else if ("error" in res) {
                        showToast(`❌ ${res.error}`, 2600);
                    }
                } catch (e) {
                    showToast(`❌ ${getErrorMessage(e)}`, 2600);
                } finally {
                    setBusyTarget(null);
                }
            });
        },
        [mePlayerId, lobbyId, showToast]
    );

    const onTransfer = useCallback(
        (targetPlayerId: string, targetName: string) => {
            if (!mePlayerId || !lobbyId) return;
            if (!confirm(`Host-Rolle an ${targetName} übertragen?`)) return;

            setBusyTarget(targetPlayerId);
            startTransition(async () => {
                try {
                    const res = await transferHostAction({ lobbyId, mePlayerId, newHostPlayerId: targetPlayerId, sessionToken: getSessionToken() ?? "" });
                    if (res.ok) {
                        showToast(`👑 ${targetName} ist jetzt Host`, 1600);
                    } else if ("error" in res) {
                        showToast(`❌ ${res.error}`, 2600);
                    }
                } catch (e) {
                    showToast(`❌ ${getErrorMessage(e)}`, 2600);
                } finally {
                    setBusyTarget(null);
                }
            });
        },
        [mePlayerId, lobbyId, showToast]
    );

    const onToggleLock = useCallback(() => {
        if (!mePlayerId || !lobbyId) return;
        const next = !isLocked;
        startTransition(async () => {
            try {
                const res = await setLobbyLockAction({ lobbyId, mePlayerId, locked: next, sessionToken: getSessionToken() ?? "" });
                if (res.ok) {
                    showToast(next ? "🔒 Lobby gesperrt" : "🔓 Lobby offen", 1400);
                } else if ("error" in res) {
                    showToast(`❌ ${res.error}`, 2600);
                }
            } catch (e) {
                showToast(`❌ ${getErrorMessage(e)}`, 2600);
            }
        });
    }, [mePlayerId, lobbyId, isLocked, showToast]);

    // ---- Lobby-Einstellungen (aus /lobby/[code]/settings hierher verschoben,
    // damit das Admin Panel nach der Erstellung tatsächlich der Ort ist, an
    // dem der Host alles verwalten kann -- nicht eine zweite, unverlinkte Seite) ----
    const [settingsBusy, setSettingsBusy] = useState(false);
    const [topicDraft, setTopicDraft] = useState("");

    useEffect(() => {
        setTopicDraft(lobby?.topic ?? "");
    }, [lobby?.topic]);

    const maxPlayers = lobby?.max_players ?? 8;
    const mode = ((lobby?.game_mode ?? "original") as ModeKey) ?? "original";
    const answerMode = ((lobby?.answer_mode ?? "text") as AnswerModeKey) ?? "text";
    const privacy = lobby?.privacy === "public" ? "public" : "private";
    const musicGenres = useMemo(() => lobby?.topic_filter ?? [], [lobby?.topic_filter]);

    const runSetting = useCallback(
        (fn: () => PromiseLike<{ error: { message: string } | null }>, okMsg: string) => {
            if (!amIHost || !mePlayerId || !lobbyId || settingsBusy) return;
            setSettingsBusy(true);
            void (async () => {
                try {
                    const { error: rpcErr } = await fn();
                    if (rpcErr) {
                        showToast(`❌ ${rpcErr.message}`, 2400);
                        return;
                    }
                    showToast(okMsg);
                } catch (e) {
                    showToast(`❌ ${getErrorMessage(e)}`, 2400);
                } finally {
                    setSettingsBusy(false);
                }
            })();
        },
        [amIHost, mePlayerId, lobbyId, settingsBusy, showToast]
    );

    const setMaxPlayersSetting = useCallback(
        (next: number) => {
            if (!mePlayerId || !lobbyId) return;
            const supabase = getSupabaseClient();
            runSetting(
                () => supabase.rpc("set_max_players", { p_lobby_id: lobbyId, p_me_player_id: mePlayerId, p_max_players: next }),
                "✅ Max-Spieler gespeichert"
            );
        },
        [mePlayerId, lobbyId, runSetting]
    );

    const setModeSetting = useCallback(
        (next: ModeKey) => {
            if (!mePlayerId || !lobbyId) return;
            const supabase = getSupabaseClient();
            runSetting(
                () => supabase.rpc("set_lobby_mode", { p_lobby_id: lobbyId, p_me_player_id: mePlayerId, p_mode: next }),
                "✅ Modus gespeichert"
            );
        },
        [mePlayerId, lobbyId, runSetting]
    );

    const setAnswerModeSetting = useCallback(
        (next: AnswerModeKey) => {
            if (!mePlayerId || !lobbyId) return;
            const supabase = getSupabaseClient();
            runSetting(
                () => supabase.rpc("set_lobby_answer_mode", { p_lobby_id: lobbyId, p_me_player_id: mePlayerId, p_answer_mode: next }),
                "✅ Antwort-Modus gespeichert"
            );
        },
        [mePlayerId, lobbyId, runSetting]
    );

    const setPrivacySetting = useCallback(
        (next: "private" | "public") => {
            if (!mePlayerId || !lobbyId) return;
            const supabase = getSupabaseClient();
            runSetting(
                () => supabase.rpc("set_lobby_privacy", { p_lobby_id: lobbyId, p_me_player_id: mePlayerId, p_privacy: next }),
                next === "public" ? "🌐 Lobby ist jetzt öffentlich" : "🔒 Lobby ist jetzt privat"
            );
        },
        [mePlayerId, lobbyId, runSetting]
    );

    const toggleGenreSetting = useCallback(
        (key: string) => {
            if (!mePlayerId || !lobbyId) return;
            const next = musicGenres.includes(key) ? musicGenres.filter((g) => g !== key) : [...musicGenres, key];
            const supabase = getSupabaseClient();
            runSetting(
                () => supabase.rpc("set_lobby_topic_filter", { p_lobby_id: lobbyId, p_me_player_id: mePlayerId, p_categories: next }),
                "✅ Musik-Genres gespeichert"
            );
        },
        [mePlayerId, lobbyId, musicGenres, runSetting]
    );

    const saveTopicSetting = useCallback(() => {
        if (!mePlayerId || !lobbyId) return;
        const supabase = getSupabaseClient();
        runSetting(
            () => supabase.rpc("set_lobby_topic", { p_lobby_id: lobbyId, p_me_player_id: mePlayerId, p_topic: topicDraft }),
            "✅ Thema gespeichert"
        );
    }, [mePlayerId, lobbyId, topicDraft, runSetting]);

    if (loading && !lobby) {
        return (
            <main className="container">
                <div style={{ display: "grid", placeItems: "center", padding: 32 }}>
                    <Spinner size={28} label="Lade Admin Panel…" />
                </div>
            </main>
        );
    }

    if (!lobby) {
        return (
            <main className="container">
                <div style={{ display: "grid", placeItems: "center", padding: 32, color: "white" }}>
                    <div style={{ fontWeight: 950 }}>{error || "Lobby nicht gefunden."}</div>
                    <Link href="/" className="btn btnSecondary btnSmall" style={{ marginTop: 12 }}>
                        ← Hauptmenü
                    </Link>
                </div>
            </main>
        );
    }

    if (!amIHost) {
        return null; // redirected
    }

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Lobby Admin">
                    <header className="hostHeader" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10 }}>
                        <div>
                            <h1 className="h1" style={{ marginBottom: 6 }}>⚙️ Admin</h1>
                            <p className="p hostSub" style={{ marginTop: 0 }}>
                                Lobby <b>{code}</b> · {players.length} Spieler
                            </p>
                        </div>

                        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                            <button
                                type="button"
                                onClick={onToggleLock}
                                className={`btn btnSmall ${isLocked ? "btnReadyOff" : "btnSecondary"}`}
                                disabled={pending}
                                title={isLocked ? "Lobby ist gesperrt – klick zum Öffnen" : "Lobby offen – klick zum Sperren"}
                            >
                                {pending ? <Spinner size={14} /> : isLocked ? "🔒 Gesperrt" : "🔓 Offen"}
                            </button>

                            <Link href={`/lobby/${encodeURIComponent(code)}`} className="btn btnSecondary btnSmall">
                                ← Zur Lobby
                            </Link>
                        </div>
                    </header>

                    <div className="stepsWrap" style={{ marginTop: 14 }}>
                        <div className="stepsBox">
                            <div className="stepsTitle">Lobby-Einstellungen</div>

                            <div className="pillCard" style={{ marginTop: 10 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">Max. Spieler</div>
                                    <div className="pillCardHint">Aktiv: {players.length}</div>
                                </div>
                                <div style={{ display: "flex", gap: 10, alignItems: "center", justifyContent: "space-between", marginTop: 10 }}>
                                    <button
                                        type="button"
                                        className="btn btnSecondary btnSmall"
                                        onClick={() => setMaxPlayersSetting(Math.max(2, maxPlayers - 1))}
                                        disabled={settingsBusy || maxPlayers <= 2 || maxPlayers - 1 < players.length}
                                        title={maxPlayers - 1 < players.length ? "Zu klein für aktive Spieler" : "Verringern"}
                                    >
                                        −
                                    </button>
                                    <div className="pillChip" style={{ height: 34, display: "flex", alignItems: "center" }}>{maxPlayers}</div>
                                    <button
                                        type="button"
                                        className="btn btnSecondary btnSmall"
                                        onClick={() => setMaxPlayersSetting(Math.min(12, maxPlayers + 1))}
                                        disabled={settingsBusy || maxPlayers >= 12}
                                    >
                                        +
                                    </button>
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">Modus</div>
                                </div>
                                <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 10 }}>
                                    {(Object.keys(MODES) as ModeKey[]).map((k) => (
                                        <button
                                            key={k}
                                            type="button"
                                            className={`btn btnSecondary btnSmall ${mode === k ? "btnGlow" : ""}`}
                                            onClick={() => setModeSetting(k)}
                                            disabled={settingsBusy}
                                        >
                                            {MODES[k].icon} {MODES[k].label}
                                        </button>
                                    ))}
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">Antwort-Modus</div>
                                </div>
                                <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 10 }}>
                                    {(Object.keys(ANSWER_MODES) as AnswerModeKey[]).map((k) => (
                                        <button
                                            key={k}
                                            type="button"
                                            className={`btn btnSecondary btnSmall ${answerMode === k ? "btnGlow" : ""}`}
                                            onClick={() => setAnswerModeSetting(k)}
                                            disabled={settingsBusy}
                                        >
                                            {ANSWER_MODES[k].icon} {ANSWER_MODES[k].label}
                                        </button>
                                    ))}
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">Privatsphäre</div>
                                    <div className="pillCardHint">{privacy === "public" ? "In der Übersicht sichtbar" : "Nur mit Code"}</div>
                                </div>
                                <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
                                    <button
                                        type="button"
                                        className={`btn btnSecondary btnSmall ${privacy === "private" ? "btnGlow" : ""}`}
                                        onClick={() => setPrivacySetting("private")}
                                        disabled={settingsBusy}
                                    >
                                        🔒 Privat
                                    </button>
                                    <button
                                        type="button"
                                        className={`btn btnSecondary btnSmall ${privacy === "public" ? "btnGlow" : ""}`}
                                        onClick={() => setPrivacySetting("public")}
                                        disabled={settingsBusy}
                                    >
                                        🌐 Public
                                    </button>
                                </div>
                            </div>

                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">🎵 Musik-Genre-Filter</div>
                                    <div className="pillCardHint">
                                        {musicGenres.length === 0 ? "Optional — sonst alle Themen gemischt" : `${musicGenres.length} ausgewählt`}
                                    </div>
                                </div>
                                <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 10 }}>
                                    {MUSIC_GENRE_KEYS.map((key) => {
                                        const g = MUSIC_PLAYLISTS[key];
                                        const active = musicGenres.includes(key);
                                        return (
                                            <button
                                                key={key}
                                                type="button"
                                                className={`pillSegBtn segChoice ${active ? "segChoiceActive" : ""}`}
                                                data-variant={key}
                                                onClick={() => toggleGenreSetting(key)}
                                                disabled={settingsBusy}
                                                title={`Playlist: ${g.title}`}
                                            >
                                                <span className="segIcon" aria-hidden>{g.icon}</span>
                                                <span className="segLabel">{key}</span>
                                            </button>
                                        );
                                    })}
                                </div>
                            </div>

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
                                    <button type="button" className="btn btnPrimary btnSmall" onClick={saveTopicSetting} disabled={settingsBusy}>
                                        💾 Speichern
                                    </button>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div className="stepsWrap" style={{ marginTop: 14 }}>
                        <div className="stepsBox">
                            <div className="stepsTitle">Spieler verwalten</div>

                            {players.length === 0 ? (
                                <div style={{ padding: "12px 8px", opacity: 0.75 }}>Noch niemand beigetreten.</div>
                            ) : (
                                <div className="playerGrid playerGridAdmin">
                                    {players.map((p, idx) => {
                                        const isMe = !!mePlayerId && p.player_id === mePlayerId;
                                        const isHostRow = !!lobby.host_player_id && p.player_id === lobby.host_player_id;
                                        const rowBusy = busyTarget === p.player_id && pending;

                                        return (
                                            <div key={p.player_id} className={`playerChip playerChipAdmin ${isHostRow ? "playerChipHost" : ""}`}>
                                                <span className="playerChipSeat">{idx + 1}</span>
                                                <span className="playerChipName">
                                                    {p.name}
                                                    {isMe ? <span style={{ opacity: 0.6 }}> (du)</span> : null}
                                                    {isHostRow ? <span className="playerChipHostBadge">👑</span> : null}
                                                </span>
                                                <span className="playerChipState">{p.ready ? "✅" : "⏳"}</span>
                                                <div className="playerChipAdminActions">
                                                    {!isHostRow ? (
                                                        <button
                                                            type="button"
                                                            className="btn btnSecondary btnSmall"
                                                            disabled={pending}
                                                            onClick={() => onTransfer(p.player_id, p.name)}
                                                            title="Host übertragen"
                                                        >
                                                            {rowBusy ? <Spinner size={14} /> : "👑"}
                                                        </button>
                                                    ) : null}
                                                    {!isMe ? (
                                                        <button
                                                            type="button"
                                                            className="btn btnReadyOff btnSmall"
                                                            disabled={pending}
                                                            onClick={() => onKick(p.player_id, p.name)}
                                                            title="Aus der Lobby kicken"
                                                        >
                                                            {rowBusy ? <Spinner size={14} /> : "👢"}
                                                        </button>
                                                    ) : null}
                                                </div>
                                            </div>
                                        );
                                    })}
                                </div>
                            )}
                        </div>
                    </div>

                    <ToastStack toasts={toasts} />
                </section>
            </div>
        </main>
    );
}
