"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState, useTransition } from "react";
import { useParams, useRouter } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";
import { LobbyNotFound, isNotFoundError } from "@/components/LobbyNotFound";
import { useHeartbeat } from "@/hooks/useHeartbeat";
import { useToastStack } from "@/hooks/useToastStack";
import { ToastStack } from "@/components/ToastStack";
import { Spinner } from "@/components/Spinner";
import { kickPlayerAction, setLobbyLockAction, transferHostAction } from "@/actions/hostActions";
import { getSessionToken } from "@/lib/playerSession";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { errorText } from "@/lib/errorText";
import { tk, trNow, useI18n } from "@/lib/i18n";
import { PlaylistPicker, usePlaylists } from "@/components/PlaylistPicker";
import { HomeButton } from "@/components/BackButton";

const GAME_PHASES = new Set(["topic_vote", "countdown", "running"]);

type ModeKey = "original" | "teleport" | "reverse";
const MODES: Record<ModeKey, { label: string; icon: string }> = {
    original: { label: tk("Original"), icon: "🥔" },
    teleport: { label: tk("Teleport"), icon: "🌀" },
    reverse: { label: tk("Reverse"), icon: "🔁" },
};

function getErrorMessage(e: unknown): string {
    if (e instanceof Error) return errorText(e.message);
    if (typeof e === "string") return e;
    try {
        return JSON.stringify(e);
    } catch {
        return trNow("Unbekannter Fehler.");
    }
}

export default function LobbyAdminPage() {
    const { tr } = useI18n();
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
            if (!confirm(trNow("{name} wirklich aus der Lobby kicken?", { name: targetName }))) return;

            setBusyTarget(targetPlayerId);
            startTransition(async () => {
                try {
                    const res = await kickPlayerAction({ lobbyId, mePlayerId, targetPlayerId, sessionToken: getSessionToken() ?? "" });
                    if (res.ok) {
                        showToast(trNow("👢 {name} gekickt", { name: targetName }), 1400);
                    } else if ("error" in res) {
                        showToast(`❌ ${errorText(res.error)}`, 2600);
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
            if (!confirm(trNow("Host-Rolle an {name} übertragen?", { name: targetName }))) return;

            setBusyTarget(targetPlayerId);
            startTransition(async () => {
                try {
                    const res = await transferHostAction({ lobbyId, mePlayerId, newHostPlayerId: targetPlayerId, sessionToken: getSessionToken() ?? "" });
                    if (res.ok) {
                        showToast(trNow("👑 {name} ist jetzt Host", { name: targetName }), 1600);
                    } else if ("error" in res) {
                        showToast(`❌ ${errorText(res.error)}`, 2600);
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
                    showToast(next ? trNow("🔒 Lobby gesperrt") : trNow("🔓 Lobby offen"), 1400);
                } else if ("error" in res) {
                    showToast(`❌ ${errorText(res.error)}`, 2600);
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

    const maxPlayers = lobby?.max_players ?? 8;
    const mode = ((lobby?.game_mode ?? "original") as ModeKey) ?? "original";
    const playlistList = usePlaylists();
    // Kein Filter in der Lobby = alle Playlists
    const musicGenres = useMemo(
        () => (lobby?.topic_filter && lobby.topic_filter.length ? lobby.topic_filter : (playlistList ?? []).map((p) => p.name)),
        [lobby?.topic_filter, playlistList]
    );

    const runSetting = useCallback(
        (fn: () => PromiseLike<{ error: { message: string } | null }>, okMsg: string) => {
            if (!amIHost || !mePlayerId || !lobbyId || settingsBusy) return;
            setSettingsBusy(true);
            void (async () => {
                try {
                    const { error: rpcErr } = await fn();
                    if (rpcErr) {
                        showToast(`❌ ${errorText(rpcErr.message)}`, 2400);
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
                trNow("✅ Max. Spieler gespeichert")
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
                trNow("✅ Modus gespeichert")
            );
        },
        [mePlayerId, lobbyId, runSetting]
    );

    const setGenresSetting = useCallback(
        (selected: string[]) => {
            if (!mePlayerId || !lobbyId) return;
            const all = (playlistList ?? []).map((p) => p.name);
            const next = all.length && all.every((n) => selected.includes(n)) ? [] : selected;
            const supabase = getSupabaseClient();
            runSetting(
                () => supabase.rpc("set_lobby_topic_filter", { p_lobby_id: lobbyId, p_me_player_id: mePlayerId, p_categories: next }),
                trNow("✅ Playlists gespeichert")
            );
        },
        [mePlayerId, lobbyId, playlistList, runSetting]
    );

    if (loading && !lobby) {
        return (
            <main className="container">
                <div style={{ display: "grid", placeItems: "center", padding: 32 }}>
                    <Spinner size={28} label={tr("Lade Einstellungen…")} />
                </div>
            </main>
        );
    }

    if (!lobby && isNotFoundError(error)) return <LobbyNotFound code={code} />;

    if (!lobby) {
        return (
            <main className="container">
                <div style={{ display: "grid", placeItems: "center", padding: 32, color: "white" }}>
                    <div style={{ fontWeight: 950 }}>{error || tr("Lobby nicht gefunden.")}</div>
                    <HomeButton className="" />
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
                <section className="card" aria-label={tr("Lobby-Einstellungen")}>
                    <header className="hostHeader" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 10 }}>
                        <div>
                            <h1 className="h1" style={{ marginBottom: 6 }}>⚙️ {tr("Einstellungen")}</h1>
                            <p className="p hostSub" style={{ marginTop: 0 }}>
                                {tr("Lobby")} <b>{code}</b> · {tr("{n} Spieler", { n: players.length })}
                            </p>
                        </div>

                        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                            <button
                                type="button"
                                onClick={onToggleLock}
                                className={`btn btnSmall ${isLocked ? "btnReadyOff" : "btnSecondary"}`}
                                disabled={pending}
                                title={isLocked ? tr("Lobby ist gesperrt – klick zum Öffnen") : tr("Lobby offen – klick zum Sperren")}
                            >
                                {pending ? <Spinner size={14} /> : isLocked ? tr("🔒 Gesperrt") : tr("🔓 Offen")}
                            </button>

                            <Link href={`/lobby/${encodeURIComponent(code)}`} className="btn btnSecondary btnSmall">
                                {tr("← Zur Lobby")}
                            </Link>
                        </div>
                    </header>

                    <div className="stepsWrap" style={{ marginTop: 14 }}>
                        <div className="stepsBox">
                            <div className="stepsTitle">{tr("Lobby-Einstellungen")}</div>

                            <div className="pillCard" style={{ marginTop: 10 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">{tr("Max. Spieler")}</div>
                                    <div className="pillCardHint">{tr("Aktiv: {n} · empfohlen 4–8 · max. 12", { n: players.length })}</div>
                                </div>
                                <div style={{ display: "flex", gap: 10, alignItems: "center", justifyContent: "space-between", marginTop: 10 }}>
                                    <button
                                        type="button"
                                        className="btn btnSecondary btnSmall"
                                        onClick={() => setMaxPlayersSetting(Math.max(2, maxPlayers - 1))}
                                        disabled={settingsBusy || maxPlayers <= 2 || maxPlayers - 1 < players.length}
                                        title={maxPlayers - 1 < players.length ? tr("Zu klein für die aktiven Spieler") : tr("Verringern")}
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
                                    <div className="pillCardTitle">{tr("Modus")}</div>
                                </div>
                                <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 10 }}>
                                    {(Object.keys(MODES) as ModeKey[]).map((k) => (
                                        <button
                                            key={k}
                                            type="button"
                                            className={`btn btnSecondary btnSmall ${mode === k ? "btnGlow" : ""}`}
                                            onClick={() => setModeSetting(k)}
                                            disabled={settingsBusy || k !== "original"}
                                            title={k !== "original" ? tr("Kommt bald") : undefined}
                                        >
                                            {MODES[k].icon} {tr(MODES[k].label)}
                                            {k !== "original" ? <span style={{ opacity: 0.7, fontSize: 11, marginLeft: 6 }}>{tr("BALD")}</span> : null}
                                        </button>
                                    ))}
                                </div>
                            </div>


                            <div className="pillCard" style={{ marginTop: 14 }}>
                                <div className="pillCardTop">
                                    <div className="pillCardTitle">🎵 Playlists</div>
                                    <div className="pillCardHint">{tr("Antippen = rausnehmen · gilt ab der nächsten Playlist-Wahl")}</div>
                                </div>
                                <div style={{ marginTop: 10 }}>
                                    <PlaylistPicker selected={musicGenres} onChange={setGenresSetting} disabled={settingsBusy} />
                                </div>
                            </div>

                        </div>
                    </div>

                    <div className="stepsWrap" style={{ marginTop: 14 }}>
                        <div className="stepsBox">
                            <div className="stepsTitle">{tr("Spieler verwalten")}</div>

                            {players.length === 0 ? (
                                <div style={{ padding: "12px 8px", opacity: 0.75 }}>{tr("Noch niemand beigetreten.")}</div>
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
                                                    {isMe ? <span style={{ opacity: 0.6 }}> ({tr("du")})</span> : null}
                                                    {isHostRow ? <span className="playerChipHostBadge">👑</span> : null}
                                                </span>
                                                <span className="playerChipState">{p.ready ? "✅" : "⏳"}</span>
                                                <div className="playerChipAdminActions">
                                                    {!isHostRow && !p.is_bot ? (
                                                        <button
                                                            type="button"
                                                            className="btn btnSecondary btnSmall"
                                                            disabled={pending}
                                                            onClick={() => onTransfer(p.player_id, p.name)}
                                                            title={tr("Host übertragen")}
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
                                                            title={tr("Aus der Lobby kicken")}
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
