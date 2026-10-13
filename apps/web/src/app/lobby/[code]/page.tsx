"use client";

import { AchievementRecap } from "@/components/AchievementRecap";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { startGame, type StartGameResult } from "@/actions/startGame";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";
import { useHeartbeat } from "@/hooks/useHeartbeat";
import { HomeFriends } from "@/components/HomeFriends";
import { RulesCard } from "@/components/RulesCard";
import { LobbyNotFound, isNotFoundError } from "@/components/LobbyNotFound";
import { InviteActions } from "@/components/InviteActions";
import { Spinner } from "@/components/Spinner";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { errorText } from "@/lib/errorText";
import { trNow, useI18n } from "@/lib/i18n";
import { getSessionToken } from "@/lib/playerSession";
import { GAME_MODES } from "@/lib/gameModes";
import { SwipeStat } from "@/components/lobby/SwipeStat";
import { Collapse } from "@/components/ui/Collapse";
import { PlaylistPicker, usePlaylists } from "@/components/PlaylistPicker";
import { kickPlayerAction, setLobbyLockAction, transferHostAction } from "@/actions/hostActions";


function getErrorMessage(e: unknown): string {
    if (e instanceof Error) return errorText(e.message);
    if (typeof e === "string") return e;
    try {
        return JSON.stringify(e);
    } catch {
        return trNow("Unbekannter Fehler.");
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

const GAME_PHASES = new Set(["topic_vote", "countdown", "running", "quiz"]);

/**
 * Einstellung, die der Host in einer Kachel ändert: zeigt sofort den neuen Wert, schickt ihn erst nach
 * einer kurzen Pause (schnelles Wischen über mehrere Werte = nur eine Anfrage) und übernimmt danach
 * wieder den Server-Stand.
 */
function useLiveSetting<T>(server: T, send: (v: T) => Promise<string | null>, onError: (msg: string) => void, reload: () => unknown) {
    const [local, setLocal] = useState<{ v: T } | null>(null);
    const timer = useRef<number | null>(null);
    const set = useCallback(
        (v: T) => {
            setLocal({ v });
            if (timer.current) window.clearTimeout(timer.current);
            timer.current = window.setTimeout(async () => {
                timer.current = null;
                const err = await send(v);
                if (err) onError(err);
                await reload();
                if (!timer.current) setLocal(null);
            }, 450);
        },
        [send, onError, reload]
    );
    useEffect(() => () => {
        if (timer.current) window.clearTimeout(timer.current);
    }, []);
    return [local ? local.v : server, set] as const;
}

export default function LobbyPage() {
    const params = useParams<{ code: string }>();
    const router = useRouter();

    const code = String(params.code ?? "").toUpperCase();
    const { mePlayerId } = usePlayerIdentity();

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

    const { lobby, players, loading, error, reload } = useLobbyState(code, { pollMs: 900 });
    const { tr } = useI18n();

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
        staleSeconds: 45,
    });

    // Realtime + Polling werden zentral in useLobbyState orchestriert.

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

                // "/" statt "/host": wer nur beigetreten war, soll nicht auf der
                // "Lobby erstellen"-Seite landen, siehe LobbyExitNotice.
                go(status === "kicked" ? `/?kicked=1` : `/?left=1`);
            } catch {
                clearMyIdentityStorage();
                suppressRedirectRef.current = true;
                go(`/`);
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
    const showError = useCallback((m: string) => showToast(`❌ ${errorText(m)}`, 2600), [showToast]);

    // ---- Einstellungen direkt in den Kacheln (nur Host, nur vor dem Start) ----
    const canEdit = amIHost && !isRunning;
    const rpc = useCallback(
        async (fn: string, args: Record<string, unknown>) => {
            if (!lobbyId || !mePlayerId) return "not_a_member";
            const { error: e } = await getSupabaseClient().rpc(fn, { p_lobby_id: lobbyId, p_me_player_id: mePlayerId, ...args });
            return e ? e.message : null;
        },
        [lobbyId, mePlayerId]
    );
    const [maxPlayers, setMaxPlayers] = useLiveSetting(
        lobby?.max_players ?? 6,
        useCallback((v: number) => rpc("set_max_players", { p_max_players: v }), [rpc]),
        showError,
        reload
    );
    const [mode, setMode] = useLiveSetting(
        lobby?.game_mode ?? "original",
        useCallback((v: string) => rpc("set_lobby_mode", { p_mode: v }), [rpc]),
        showError,
        reload
    );
    const [rounds, setRounds] = useLiveSetting(
        lobby?.series_total ?? 1,
        useCallback((v: number) => rpc("set_lobby_series", { p_total: v }), [rpc]),
        showError,
        reload
    );
    // Sichtbarkeit: offen (im Hauptmenü) / privat (nur mit Code) / gesperrt (keiner kommt mehr rein)
    const serverVisibility: string = lobby?.locked ? "locked" : lobby?.privacy === "public" ? "public" : "private";
    const sendVisibility = useCallback(
        async (v: string) => {
            if (!lobbyId || !mePlayerId) return "not_a_member";
            const wantLocked = v === "locked";
            if (!!lobby?.locked !== wantLocked) {
                const res = await setLobbyLockAction({ lobbyId, mePlayerId, locked: wantLocked, sessionToken: getSessionToken() ?? "" });
                if (!res.ok) return "error" in res ? res.error : "error";
            }
            if (!wantLocked) return rpc("set_lobby_privacy", { p_privacy: v });
            return null;
        },
        [lobbyId, mePlayerId, lobby?.locked, rpc]
    );
    const [visibility, setVisibility] = useLiveSetting(serverVisibility, sendVisibility, showError, reload);

    // Playlists (die einzige Stelle, an der man sie ändert)
    const playlistList = usePlaylists();
    const [plOpen, setPlOpen] = useState(false);
    const activePlaylists = useMemo(
        () => (lobby?.topic_filter && lobby.topic_filter.length ? lobby.topic_filter : (playlistList ?? []).map((p) => p.name)),
        [lobby?.topic_filter, playlistList]
    );
    const setPlaylists = useCallback(
        async (selected: string[]) => {
            const all = (playlistList ?? []).map((p) => p.name);
            const next = all.length && all.every((n) => selected.includes(n)) ? [] : selected;
            const err = await rpc("set_lobby_topic_filter", { p_categories: next });
            if (err) showError(err);
            void reload();
        },
        [playlistList, rpc, showError, reload]
    );

    // Spieler verwalten (Host): kicken / Host übergeben
    const [manageBusy, setManageBusy] = useState<string | null>(null);
    const kickPlayer = useCallback(
        async (id: string, name: string) => {
            if (!lobbyId || !mePlayerId || !confirm(trNow("{name} wirklich aus der Lobby kicken?", { name }))) return;
            setManageBusy(id);
            const res = await kickPlayerAction({ lobbyId, mePlayerId, targetPlayerId: id, sessionToken: getSessionToken() ?? "" });
            setManageBusy(null);
            if (!res.ok) showError("error" in res ? res.error : "error");
            else showToast(trNow("👢 {name} gekickt", { name }), 1400);
            void reload();
        },
        [lobbyId, mePlayerId, showError, showToast, reload]
    );
    const makeHost = useCallback(
        async (id: string, name: string) => {
            if (!lobbyId || !mePlayerId || !confirm(trNow("Host-Rolle an {name} übertragen?", { name }))) return;
            setManageBusy(id);
            const res = await transferHostAction({ lobbyId, mePlayerId, newHostPlayerId: id, sessionToken: getSessionToken() ?? "" });
            setManageBusy(null);
            if (!res.ok) showError("error" in res ? res.error : "error");
            else showToast(trNow("👑 {name} ist jetzt Host", { name }), 1600);
            void reload();
        },
        [lobbyId, mePlayerId, showError, showToast, reload]
    );

    // Code antippen kopiert nur den 4-stelligen Code (z. B. zum Vorlesen/Abtippen).
    // Teilen, Link und QR-Code liegen gesammelt in <InviteActions> darunter.
    const copyCode = useCallback(async () => {
        try {
            await navigator.clipboard.writeText(code);
            showToast(trNow("✅ Code kopiert"), 1200);
        } catch {
            showToast(trNow("⚠️ Kopieren nicht möglich"), 1600);
        }
    }, [code, showToast]);

    const meReady = useMemo(() => {
        if (!mePlayerId) return false;
        const row = players.find((p) => p.player_id === mePlayerId);
        return !!row?.ready;
    }, [players, mePlayerId]);

    const MIN_PLAYERS = 2;
    // Der Host muss NICHT mehr selbst "Bereit" klicken, um starten zu können --
    // sobald alle ANDEREN aktiven Spieler bereit sind, reicht das. Der Host
    // sitzt eh am Start-Button, ein zusätzlicher Klick auf "Bereit" davor war
    // nur ein unnötiger Zwischenschritt.
    const allReady = useMemo(() => {
        const others = players.filter((p) => p.player_id !== lobby?.host_player_id);
        return players.length >= MIN_PLAYERS && others.every((p) => !!p.ready);
    }, [players, lobby?.host_player_id]);

    const toggleReady = useCallback(async () => {
        if (!mePlayerId) return;
        if (!lobbyId) return;
        if (busyReady || starting || isRunning) return;

        setBusyReady(true);
        try {
            const supabase = getSupabaseClient();

            const { error: rpcErr } = await supabase.rpc("rpc_toggle_ready", {
                p_lobby_id: lobbyId,
                p_player_id: mePlayerId,
            });

            if (rpcErr) showToast(`❌ ${errorText(rpcErr.message)}`, 2500);
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
            const res: StartGameResult = await startGame(code, mePlayerId, getSessionToken() ?? "");

            if (!res.ok) {
                const msg = "error" in res ? errorText(res.error) : trNow("Start fehlgeschlagen");
                showToast(`❌ ${msg}`, 2500);
                return;
            }

            // ✅ No immediate navigation; DB phase triggers redirect
            showToast(trNow("✅ Spiel startet…"), 900);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2500);
        } finally {
            setStarting(false);
        }
    }, [amIHost, mePlayerId, starting, isRunning, code, showToast]);

    const [botBusy, setBotBusy] = useState(false);
    // Stärke des nächsten Bots: 0 = gemischt (Zufall), 1 = Anfänger, 2 = Mittel, 3 = Profi
    const [botSkill, setBotSkill] = useState<0 | 1 | 2 | 3>(0);
    // Namen, die schon per rpc_add_bot verschickt wurden -- die `players`-Liste
    // kommt erst per Realtime nach (spürbare Lücke), ein schneller zweiter Klick
    // sah sonst noch den alten Stand und griff sich denselben Namen nochmal.
    const dispatchedBotNamesRef = useRef<Set<string>>(new Set());

    const addBot = useCallback(async () => {
        if (!amIHost || !mePlayerId || !lobbyId) return;
        if (botBusy) return;
        setBotBusy(true);
        try {
            const supabase = getSupabaseClient();
            const names = ["Bot Anna", "Bot Ben", "Bot Cleo", "Bot Dino", "Bot Echo", "Bot Fips", "Bot Gala", "Bot Hugo", "Bot Iris", "Bot Jay"];
            const taken = new Set(players.map((p) => p.name));
            for (const n of dispatchedBotNamesRef.current) taken.add(n);
            const free = names.find((n) => !taken.has(n)) ?? `Bot ${Math.floor(Math.random() * 999)}`;
            dispatchedBotNamesRef.current.add(free);

            const { error: rpcErr } = await supabase.rpc("rpc_add_bot", {
                p_lobby_id: lobbyId,
                p_me_player_id: mePlayerId,
                p_bot_name: free,
                ...(botSkill > 0 ? { p_skill: botSkill } : {}),
            });
            if (rpcErr) {
                dispatchedBotNamesRef.current.delete(free);
                showToast(`❌ ${errorText(rpcErr.message)}`, 2400);
            }
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2400);
        } finally {
            setBotBusy(false);
        }
    }, [amIHost, mePlayerId, lobbyId, players, botBusy, botSkill, showToast]);

    const removeBot = useCallback(async (botPlayerId: string) => {
        if (!amIHost || !mePlayerId || !lobbyId) return;
        if (botBusy) return;
        setBotBusy(true);
        try {
            const supabase = getSupabaseClient();
            const { error: rpcErr } = await supabase.rpc("rpc_remove_bot", {
                p_lobby_id: lobbyId,
                p_me_player_id: mePlayerId,
                p_bot_player_id: botPlayerId,
            });
            if (rpcErr) showToast(`❌ ${errorText(rpcErr.message)}`, 2400);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2400);
        } finally {
            setBotBusy(false);
        }
    }, [amIHost, mePlayerId, lobbyId, botBusy, showToast]);

    const leaveLobby = useCallback(async () => {
        suppressRedirectRef.current = true;

        try {
            if (mePlayerId && lobbyId) {
                // Direktes UPDATE auf players wird seit Migration 012 von RLS
                // abgelehnt (der Fehler landete hier stumm im catch, der Spieler
                // blieb als Geist "active" in der Lobby). Läuft jetzt über die
                // geprüfte RPC aus Migration 022/023.
                const supabase = getSupabaseClient();
                const { error } = await supabase.rpc("rpc_leave_lobby", {
                    p_lobby_id: lobbyId,
                    p_player_id: mePlayerId,
                });
                if (error) console.error("rpc_leave_lobby:", error.message);
            }
        } catch {
            // ignore
        } finally {
            clearMyIdentityStorage();
            // "Hauptmenü" muss auch für Spieler stimmen, die nur beigetreten sind
            // (nicht gehostet haben) -- /host ist die "Lobby erstellen"-Seite und
            // ergibt für sie keinen Sinn. "/" bietet beide Optionen (Host + Join).
            go("/?left=1");
        }
    }, [mePlayerId, lobbyId, go]);

    // Unbekannter Code: statt einer leeren Lobby mit Rohfehler eine klare Seite zeigen
    if (!loading && !lobby && isNotFoundError(error)) return <LobbyNotFound code={code} />;

    const playerOptions = Array.from({ length: 11 }, (_, i) => i + 2)
        .filter((n) => n >= players.length || n === maxPlayers)
        .map((n) => ({
            value: n,
            icon: "👥",
            label: (
                <>
                    {players.length}
                    <small> / {n}</small>
                </>
            ),
        }));
    const modeOptions = GAME_MODES.filter((m) => !m.soon || m.key === mode).map((m) => ({ value: m.key as string, icon: m.icon, label: tr(m.label), title: tr(m.desc) }));
    const roundOptions = [1, 3, 5].map((n) => ({ value: n, icon: "🎯", label: String(n) }));
    const visibilityOptions = [
        { value: "public", icon: "🌍", label: tr("Offen"), title: tr("Steht im Hauptmenü unter „Offene Lobbys“") },
        { value: "private", icon: "🔒", label: tr("Privat"), title: tr("Nur mit Code oder Einladung") },
        { value: "locked", icon: "⛔", label: tr("Gesperrt"), title: tr("Keiner kann mehr beitreten") },
    ];

    return (
        <main className="container">
            <AchievementRecap />
            <div className="landingWrap withSidePanel">
                <section className="card" aria-label={tr("Lobby")} style={{ position: "relative" }}>
                    <div className="lobbyHead">
                        {isRunning ? <div className="lobbyNotice">{tr("🚀 Spiel läuft – die Lobby ist gesperrt")}</div> : null}

                        <div className="lobbyHeadTop">
                            <h1 className="h1 lobbyTitle">{tr("Lobby")}</h1>
                            <div className="lobbyActions">
                                <button type="button" className="homeBackBtn" onClick={() => void leaveLobby()} disabled={starting}>
                                    <span aria-hidden>🏠</span> {tr("Hauptmenü")}
                                </button>
                            </div>
                        </div>

                        {/* Spielerzahl, Modus, Runden und Sichtbarkeit – der Host ändert sie direkt hier (wischen/antippen) */}
                        <div className="lobbyStats">
                            <SwipeStat label={tr("Spieler")} options={playerOptions} value={maxPlayers} onChange={setMaxPlayers} editable={canEdit} />
                            <SwipeStat label={tr("Modus")} options={modeOptions} value={mode} onChange={setMode} editable={canEdit} />
                            <SwipeStat label={rounds > 1 ? tr("Runden") : tr("Runde")} options={roundOptions} value={rounds} onChange={setRounds} editable={canEdit} />
                            <SwipeStat
                                label={tr("Sichtbarkeit")}
                                options={visibilityOptions}
                                value={visibility}
                                onChange={setVisibility}
                                editable={canEdit}
                                className={`vis-${visibility}`}
                            />
                        </div>
                        {canEdit ? <div className="lobbyStatsHint">{tr("👆 Wische über eine Kachel oder tippe sie an, um sie zu ändern.")}</div> : null}

                        <button
                            type="button"
                            className="codeBox"
                            onClick={() => void copyCode()}
                            title={tr("Klick → Code kopieren")}
                            aria-label={tr("Lobby-Code {code} kopieren", { code })}
                            disabled={isRunning}
                        >
                            <span className="codeLabel">{tr("Lobby-Code")}</span>
                            <span className="codeValue">{code}</span>
                            <span className="codeHint">{toast ? toast : tr("Tippen kopiert den Code")}</span>
                        </button>

                        <InviteActions code={code} disabled={isRunning} />

                        <div className="lobbyPl">
                            <button type="button" className="lobbyPlHead" onClick={() => setPlOpen((v) => !v)} aria-expanded={plOpen}>
                                <span>🎵 {tr("Playlists")}</span>
                                <span className="lobbyPlCount">
                                    {tr("{n} von {total} aktiv", { n: activePlaylists.length, total: playlistList?.length ?? activePlaylists.length })}
                                </span>
                                <span aria-hidden className={`lobbyPlArrow ${plOpen ? "open" : ""}`}>▾</span>
                            </button>
                            <Collapse open={plOpen}>
                                <div className="lobbyPlBody">
                                    {canEdit ? <div className="lobbyPlHint">{tr("Antippen = rausnehmen · gilt ab der nächsten Playlist-Wahl")}</div> : null}
                                    <PlaylistPicker selected={activePlaylists} onChange={(sel) => void setPlaylists(sel)} disabled={!canEdit} />
                                </div>
                            </Collapse>
                        </div>

                        {lobby?.topic ? (
                            <div className="lobbyChips">
                                <span className="pillChip" title={lobby.topic ?? undefined}>
                                    🏷️ {lobby.topic}
                                </span>
                            </div>
                        ) : null}

                        <style>{`
                .lobbyHead{ display: grid; gap: 14px; }
                .lobbyNotice{ padding: 8px 14px; border-radius: 14px; background: rgba(255,210,63,.18); border: 1px solid rgba(255,210,63,.45); font-weight: 700; }
                .lobbyHeadTop{ display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
                .lobbyTitle{ font-size: clamp(32px, 6vw, 44px) !important; }
                .lobbyActions{ display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
                .lobbyBotBtn{ font-size: 16px !important; padding: 12px 20px !important; }
                .codeBox{
                  display: grid; justify-items: center; gap: 2px; width: 100%; cursor: pointer; color: #fff;
                  padding: 14px 16px; border-radius: 22px; border: 2px dashed rgba(255,255,255,.38); background: rgba(255,255,255,.08);
                  transition: background .15s ease, border-color .15s ease, transform .15s ease;
                }
                .codeBox:hover:not(:disabled){ background: rgba(255,255,255,.14); border-color: #ffd23f; }
                .codeBox:active:not(:disabled){ transform: scale(.99); }
                .codeBox:disabled{ cursor: default; opacity: .75; }
                .codeLabel{ font-size: 11px; font-weight: 800; letter-spacing: 2px; text-transform: uppercase; opacity: .7; }
                .codeValue{ font-family: var(--font-display); font-size: clamp(44px, 12vw, 64px); font-weight: 800; letter-spacing: .18em; padding-left: .18em; line-height: 1.05; color: #ffd23f; text-shadow: 0 4px 0 rgba(120,50,0,.55), 0 10px 26px rgba(0,0,0,.35); }
                .codeHint{ font-size: 12px; opacity: .72; min-height: 16px; }
                .lobbyStats{ display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
                @media (max-width: 620px){ .lobbyStats{ grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; } }
                @media (max-width: 520px){ .lobbyStat{ padding: 10px 4px; } .lobbyStatIcon{ font-size: 22px; } .lobbyStatLabel{ font-size: 9.5px; letter-spacing: .4px; } }
                .lobbyStatsHint{ margin-top: -6px; text-align: center; font-size: 12.5px; font-weight: 700; opacity: .7; }
                .swStat.vis-locked{ background: rgba(239,68,68,.16); border-color: rgba(252,165,165,.5); }
                .lobbyPl{ border-radius: 18px; background: rgba(255,255,255,.06); border: 1px solid rgba(255,255,255,.14); overflow: hidden; }
                .lobbyPlHead{ width: 100%; display: flex; align-items: center; gap: 10px; padding: 11px 14px; background: transparent; border: 0; color: #fff; font: inherit; font-weight: 900; cursor: pointer; text-align: left; }
                .lobbyPlHead:hover{ background: rgba(255,255,255,.06); }
                .lobbyPlCount{ margin-left: auto; font-size: 12.5px; font-weight: 800; opacity: .75; }
                .lobbyPlArrow{ transition: transform .3s ease; }
                .lobbyPlArrow.open{ transform: rotate(180deg); }
                .lobbyPlBody{ padding: 0 14px 14px; display: grid; gap: 8px; }
                .lobbyPlHint{ font-size: 12.5px; font-weight: 700; opacity: .72; }
                .lobbyStat{ display: grid; justify-items: center; gap: 2px; padding: 12px 8px; border-radius: 20px; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.16); text-align: center; min-width: 0; }
                .lobbyStatIcon{ font-size: 26px; line-height: 1.1; }
                .lobbyStatValue{ font-family: var(--font-display); font-size: clamp(20px, 3.4vw, 28px); font-weight: 800; line-height: 1.1; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
                .lobbyStatValue small{ font-size: .62em; opacity: .7; }
                .lobbyStatLabel{ font-size: 11px; font-weight: 800; letter-spacing: 1.2px; text-transform: uppercase; opacity: .7; }
                .lobbyChips{ display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
                .lobbyChips .pillChip{ font-size: 13px; padding: 7px 12px; opacity: 1; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
              `}</style>
                    </div>

                    <div className="stepsWrap">
                        <div className="stepsBox">
                            <div className="stepsTitle">{tr("Spieler")}</div>
                            {error ? <p className="errorText">{error}</p> : null}

                            {loading && players.length === 0 ? (
                                <div style={{ padding: "12px 8px", opacity: 0.85 }}>
                                    <Spinner size={16} label={tr("Lade Spieler…")} />
                                </div>
                            ) : null}

                            {!loading && players.length === 0 ? (
                                <div style={{ padding: "12px 8px", opacity: 0.75 }}>{tr("Noch niemand beigetreten.")}</div>
                            ) : null}

                            <div className="playerGrid">
                                {players.map((p, idx) => {
                                    const isMe = !!mePlayerId && p.player_id === mePlayerId;
                                    const isHostRow = !!lobby?.host_player_id && p.player_id === lobby.host_player_id;

                                    return (
                                        <div
                                            key={p.player_id}
                                            className={`playerChip ${isHostRow ? "playerChipHost" : ""} ${p.ready ? "playerChipReady" : "playerChipNotReady"}`}
                                        >
                                            <span className="playerChipSeat">{idx + 1}</span>
                                            <PlayerAvatar seed={p.name} config={p.avatar_config} size={34} className="playerChipAvatar" />
                                            <span className="playerChipName">
                                                {p.is_bot ? "🤖 " : ""}
                                                {p.name}
                                                {p.is_bot && p.bot_skill ? (
                                                    <span style={{ opacity: 0.8, fontSize: 11, marginLeft: 6 }} title={tr(["", "Anfänger", "Mittel", "Profi"][p.bot_skill] ?? "")}>
                                                        {"★".repeat(p.bot_skill)}
                                                    </span>
                                                ) : null}
                                                {isMe ? <span style={{ opacity: 0.6 }}> ({tr("du")})</span> : null}
                                                {isHostRow ? <span className="playerChipHostBadge">👑</span> : null}
                                            </span>
                                            <span className="playerChipState">{p.ready ? "✅" : "⏳"}</span>
                                            {p.is_bot && amIHost ? (
                                                <button
                                                    type="button"
                                                    className="btn btnReadyOff btnSmall playerChipKick"
                                                    onClick={() => void removeBot(p.player_id)}
                                                    disabled={botBusy || isRunning}
                                                    title={tr("Bot entfernen")}
                                                >
                                                    👋
                                                </button>
                                            ) : null}
                                            {!p.is_bot && amIHost && !isMe ? (
                                                <>
                                                    <button
                                                        type="button"
                                                        className="btn btnSecondary btnSmall playerChipKick"
                                                        onClick={() => void makeHost(p.player_id, p.name)}
                                                        disabled={!!manageBusy || isRunning}
                                                        title={tr("Host übertragen")}
                                                    >
                                                        👑
                                                    </button>
                                                    <button
                                                        type="button"
                                                        className="btn btnReadyOff btnSmall playerChipKick"
                                                        onClick={() => void kickPlayer(p.player_id, p.name)}
                                                        disabled={!!manageBusy || isRunning}
                                                        title={tr("Aus der Lobby kicken")}
                                                    >
                                                        👢
                                                    </button>
                                                </>
                                            ) : null}
                                        </div>
                                    );
                                })}
                            </div>

                            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", gap: 12, marginTop: 14, flexWrap: "wrap" }}>
                                <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                                    {amIHost && !isRunning ? (
                                        <button
                                            type="button"
                                            className="btn btnPrimary lobbyBotBtn"
                                            onClick={() => void addBot()}
                                            disabled={botBusy || players.length >= (lobby?.max_players ?? 6)}
                                            title={tr("Bot zur Lobby hinzufügen (Übungsspiel)")}
                                        >
                                            {tr("🤖 Bot hinzufügen")}
                                        </button>
                                    ) : null}
                                    {amIHost && !isRunning ? (
                                        <select
                                            className="input"
                                            style={{ height: 48, width: "auto", padding: "0 14px", fontSize: 15, fontWeight: 800 }}
                                            value={botSkill}
                                            onChange={(e) => setBotSkill(Number(e.target.value) as 0 | 1 | 2 | 3)}
                                            aria-label={tr("Stärke des nächsten Bots")}
                                            title={tr("Stärke des nächsten Bots")}
                                        >
                                            <option value={0}>{tr("Stärke: gemischt")}</option>
                                            <option value={1}>★ {tr("Anfänger")}</option>
                                            <option value={2}>★★ {tr("Mittel")}</option>
                                            <option value={3}>★★★ {tr("Profi")}</option>
                                        </select>
                                    ) : null}
                                </div>

                                <button
                                    type="button"
                                    onClick={toggleReady}
                                    disabled={busyReady || !mePlayerId || starting || isRunning}
                                    className={`btn btnXL ${busyReady || starting || isRunning ? "btnDisabled" : ""} ${meReady ? "btnReadyOff" : "btnReadyOn"}`}
                                >
                                    {isRunning ? tr("🚀 Läuft") : starting ? "…" : busyReady ? "…" : meReady ? tr("⛔ Nicht bereit") : tr("✨ Bereit")}
                                </button>
                            </div>

                            {/* ✅ START BUTTON: Host + allReady */}
                            {amIHost && allReady && lobby?.phase !== "running" ? (
                                <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 10 }}>
                                    <button type="button" className="btn btnPrimary btnSmall btnGlow" onClick={() => void startGameClick()} disabled={starting || isRunning}>
                                        {tr("🚀 Spiel starten")}
                                    </button>
                                </div>
                            ) : null}

                            {!allReady ? (
                                <div style={{ marginTop: 10, opacity: 0.75, fontWeight: 800, fontSize: 13 }}>
                                    {tr("Mindestens {n} Spieler müssen beitreten und bereit sein.", { n: MIN_PLAYERS })}
                                </div>
                            ) : null}
                        </div>
                    </div>

                    <RulesCard defaultOpen />
                </section>
                {/* Freunde rechts daneben – online Freunde direkt in diese Lobby einladen */}
                <HomeFriends inviteCode={code} />
            </div>
        </main>
    );
}