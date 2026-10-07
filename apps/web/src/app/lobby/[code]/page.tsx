"use client";

import Link from "next/link";
import { startGame, type StartGameResult } from "@/actions/startGame";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";

import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyState } from "@/hooks/useLobbyState";
import { useHeartbeat } from "@/hooks/useHeartbeat";
import { useSavedLobbies } from "@/hooks/useSavedLobbies";
import { useAuth } from "@/components/AuthProvider";
import { RulesCard } from "@/components/RulesCard";
import { LobbyNotFound, isNotFoundError } from "@/components/LobbyNotFound";
import { InviteActions } from "@/components/InviteActions";
import { Spinner } from "@/components/Spinner";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { getSessionToken } from "@/lib/playerSession";

type ModeKey = "original" | "teleport" | "reverse";

const MODES: Record<ModeKey, { label: string; icon: string }> = {
    original: { label: "Original", icon: "🥔" },
    teleport: { label: "Teleport", icon: "🌀" },
    reverse: { label: "Reverse", icon: "🔁" },
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
    const { mePlayerId } = usePlayerIdentity();
    const { user } = useAuth();
    const savedLobbies = useSavedLobbies(user?.id ?? null);
    const isSaved = useMemo(() => savedLobbies.rows.some((s) => s.lobby_code === code), [savedLobbies.rows, code]);

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

    // Code antippen kopiert nur den 4-stelligen Code (z. B. zum Vorlesen/Abtippen).
    // Teilen, Link und QR-Code liegen gesammelt in <InviteActions> darunter.
    const copyCode = useCallback(async () => {
        try {
            await navigator.clipboard.writeText(code);
            showToast("✅ Code kopiert", 1200);
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
            const res: StartGameResult = await startGame(code, mePlayerId, getSessionToken() ?? "");

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
                showToast(`❌ ${rpcErr.message}`, 2400);
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
            if (rpcErr) showToast(`❌ ${rpcErr.message}`, 2400);
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

    const maxPlayers = lobby?.max_players ?? 8;
    const mode = ((lobby?.game_mode ?? "original") as ModeKey) ?? "original";

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Lobby" style={{ position: "relative" }}>
                    <div className="lobbyHead">
                        {isRunning ? <div className="lobbyNotice">🚀 Spiel läuft – Lobby ist read-only</div> : null}

                        <div className="lobbyHeadTop">
                            <h1 className="h1 lobbyTitle">Lobby</h1>
                            <div className="lobbyActions">
                                {user ? (
                                    <button
                                        type="button"
                                        className="btn btnSecondary btnSmall"
                                        onClick={async () => {
                                            if (isSaved) {
                                                await savedLobbies.unsave(code);
                                                showToast("🗑️ Aus gespeicherten Lobbies entfernt", 1500);
                                            } else {
                                                const nick = window.prompt("Spitzname für diese Lobby?", `Lobby ${code}`);
                                                if (!nick) return;
                                                await savedLobbies.save(code, nick);
                                                showToast("💾 Lobby gespeichert", 1500);
                                            }
                                        }}
                                        title={isSaved ? "Lobby ist gespeichert" : "Diese Lobby speichern"}
                                    >
                                        {isSaved ? "💾 Gespeichert" : "🔖 Merken"}
                                    </button>
                                ) : null}

                                {amIHost ? (
                                    <Link
                                        href={`/lobby/${encodeURIComponent(code)}/admin`}
                                        className={`btn btnSecondary btnSmall ${starting || isRunning ? "btnDisabled" : ""}`}
                                        aria-disabled={starting || isRunning}
                                        tabIndex={starting || isRunning ? -1 : 0}
                                        onClick={(e) => {
                                            if (starting || isRunning) e.preventDefault();
                                        }}
                                        title="Einstellungen öffnen"
                                    >
                                        ⚙️ Einstellungen
                                    </Link>
                                ) : null}
                            </div>
                        </div>

                        <button
                            type="button"
                            className="codeBox"
                            onClick={() => void copyCode()}
                            title="Klick → Code kopieren"
                            aria-label={`Lobby-Code ${code} kopieren`}
                            disabled={isRunning}
                        >
                            <span className="codeLabel">Lobby-Code</span>
                            <span className="codeValue">{code}</span>
                            <span className="codeHint">{toast ? toast : "Tippen kopiert den Code"}</span>
                        </button>

                        <InviteActions code={code} disabled={isRunning} />

                        <div className="lobbyChips">
                            <span className="pillChip">
                                👥 {players.length} / {maxPlayers}
                            </span>
                            <span className="pillChip">
                                {MODES[mode]?.icon ?? "🥔"} {MODES[mode]?.label ?? mode}
                            </span>
                            {(lobby?.series_total ?? 1) > 1 ? <span className="pillChip">🎯 {lobby?.series_total} Runden</span> : <span className="pillChip">🎯 1 Runde</span>}
                            {lobby?.topic ? (
                                <span className="pillChip" title={lobby.topic ?? undefined}>
                                    🏷️ {lobby.topic}
                                </span>
                            ) : null}
                        </div>

                        <style>{`
                .lobbyHead{ display: grid; gap: 14px; }
                .lobbyNotice{ padding: 8px 14px; border-radius: 14px; background: rgba(255,210,63,.18); border: 1px solid rgba(255,210,63,.45); font-weight: 700; }
                .lobbyHeadTop{ display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
                .lobbyTitle{ font-size: clamp(32px, 6vw, 44px) !important; }
                .lobbyActions{ display: flex; gap: 8px; flex-wrap: wrap; }
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
                .lobbyChips{ display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
                .lobbyChips .pillChip{ font-size: 13px; padding: 7px 12px; opacity: 1; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
              `}</style>
                    </div>

                    <div className="stepsWrap">
                        <div className="stepsBox">
                            <div className="stepsTitle">Spieler</div>
                            {error ? <p className="errorText">{error}</p> : null}

                            {loading && players.length === 0 ? (
                                <div style={{ padding: "12px 8px", opacity: 0.85 }}>
                                    <Spinner size={16} label="Lade Spieler…" />
                                </div>
                            ) : null}

                            {!loading && players.length === 0 ? (
                                <div style={{ padding: "12px 8px", opacity: 0.75 }}>Noch niemand beigetreten.</div>
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
                                            <span className="playerChipName">
                                                {p.is_bot ? "🤖 " : ""}
                                                {p.name}
                                                {p.is_bot && p.bot_skill ? (
                                                    <span style={{ opacity: 0.8, fontSize: 11, marginLeft: 6 }} title={["", "Anfänger", "Mittel", "Profi"][p.bot_skill]}>
                                                        {"★".repeat(p.bot_skill)}
                                                    </span>
                                                ) : null}
                                                {isMe ? <span style={{ opacity: 0.6 }}> (du)</span> : null}
                                                {isHostRow ? <span className="playerChipHostBadge">👑</span> : null}
                                            </span>
                                            <span className="playerChipState">{p.ready ? "✅" : "⏳"}</span>
                                            {p.is_bot && amIHost ? (
                                                <button
                                                    type="button"
                                                    className="btn btnReadyOff btnSmall playerChipKick"
                                                    onClick={() => void removeBot(p.player_id)}
                                                    disabled={botBusy || isRunning}
                                                    title="Bot entfernen"
                                                >
                                                    👋
                                                </button>
                                            ) : null}
                                        </div>
                                    );
                                })}
                            </div>

                            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", gap: 12, marginTop: 14, flexWrap: "wrap" }}>
                                <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                                    <button type="button" className="btn btnSecondary btnSmall" onClick={() => void leaveLobby()} disabled={starting}>
                                        ← Hauptmenü
                                    </button>
                                    {amIHost && !isRunning ? (
                                        <button
                                            type="button"
                                            className="btn btnSecondary btnSmall"
                                            onClick={() => void addBot()}
                                            disabled={botBusy || players.length >= (lobby?.max_players ?? 8)}
                                            title="Bot zur Lobby hinzufügen (Practice-Mode)"
                                        >
                                            🤖 +Bot
                                        </button>
                                    ) : null}
                                    {amIHost && !isRunning ? (
                                        <select
                                            className="input"
                                            style={{ height: 36, width: "auto", padding: "0 10px", fontSize: 13, fontWeight: 700 }}
                                            value={botSkill}
                                            onChange={(e) => setBotSkill(Number(e.target.value) as 0 | 1 | 2 | 3)}
                                            aria-label="Stärke des nächsten Bots"
                                            title="Stärke des nächsten Bots"
                                        >
                                            <option value={0}>Stärke: gemischt</option>
                                            <option value={1}>★ Anfänger</option>
                                            <option value={2}>★★ Mittel</option>
                                            <option value={3}>★★★ Profi</option>
                                        </select>
                                    ) : null}
                                </div>

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

                    <RulesCard defaultOpen />
                </section>
            </div>
        </main>
    );
}