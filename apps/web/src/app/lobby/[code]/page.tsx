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
import { Spinner } from "@/components/Spinner";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { getSessionToken } from "@/lib/playerSession";

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

    const copyInviteByClick = useCallback(async () => {
        const origin = window.location.origin;
        const link = fmtJoinLink(origin, code);
        const shareText = `Komm in meine Kumpir-Lobby! Code: ${code}\n${link}`;

        // Prefer Web Share API on mobile (System-Share-Sheet → WhatsApp/iMessage/etc.)
        const nav = navigator as Navigator & { share?: (data: ShareData) => Promise<void> };
        if (typeof nav.share === "function") {
            try {
                await nav.share({ title: "Kumpir-Lobby", text: shareText, url: link });
                return;
            } catch (e) {
                // user cancelled — silently fall through to clipboard
                if (e instanceof Error && e.name === "AbortError") return;
            }
        }

        try {
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
    }, [amIHost, mePlayerId, lobbyId, players, botBusy, showToast]);

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
                            // pointerEvents:none hier + gezieltes "auto" auf den echten
                            // Buttons darunter: der sticky Header überlappt bei kurzer
                            // Spielerliste (wenige Zeilen) geometrisch die Buttons direkt
                            // darunter (+Bot/Bereit/Hauptmenü) und blockte deren Klicks
                            // komplett, weil sein zIndex:5 einen eigenen Stacking-Context
                            // bildet, der IMMER über den unpositionierten Geschwistern liegt.
                            pointerEvents: "none",
                        }}
                    >
                        {isRunning ? (
                            <div className="pillChip" style={{ marginBottom: 10, fontWeight: 950, opacity: 0.95 }}>
                                🚀 Spiel läuft – Lobby ist read-only
                            </div>
                        ) : null}

                        <div style={{ display: "flex", justifyContent: "space-between", gap: 14, alignItems: "flex-start", flexWrap: "wrap" }}>
                            <div style={{ flex: 1, minWidth: 280 }}>
                                <h1 className="h1" style={{ marginBottom: 4 }}>
                                    Private Lobby
                                </h1>
                            </div>

                            <div style={{ display: "grid", gap: 6, justifyItems: "end", minWidth: 240 }}>
                                <div style={{ display: "grid", gap: 6, justifyItems: "end" }}>
                                    <div className="pillChip" style={{ height: 34, display: "flex", alignItems: "center", gap: 8, fontSize: 15 }}>
                                        <span style={{ opacity: 0.8 }}>👥</span>
                                        <span style={{ fontWeight: 950 }}>{players.length}</span>
                                        <span style={{ opacity: 0.8 }}>/</span>
                                        <span style={{ fontWeight: 950 }}>{maxPlayers}</span>
                                    </div>

                                    <div className="pillChip" style={{ height: 34, display: "flex", alignItems: "center", gap: 8, fontSize: 15 }}>
                                        <span>{MODES[mode]?.icon ?? "🥔"}</span>
                                        <span style={{ fontWeight: 950 }}>{MODES[mode]?.label ?? mode}</span>
                                    </div>

                                    {lobby?.topic ? (
                                        <div className="pillChip" style={{ height: 28, display: "flex", alignItems: "center", gap: 8, maxWidth: 260 }} title={lobby.topic ?? undefined}>
                                            <span style={{ opacity: 0.8 }}>🏷️</span>
                                            <span style={{ fontWeight: 900, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                        {lobby.topic}
                      </span>
                                        </div>
                                    ) : null}
                                </div>

                                {user ? (
                                    <button
                                        type="button"
                                        className="btn btnSecondary btnSmall"
                                        style={{ pointerEvents: "auto" }}
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
                                        className={`btn btnSecondary ${starting || isRunning ? "btnDisabled" : ""}`}
                                        style={{ pointerEvents: "auto", fontSize: 15, padding: "10px 16px", fontWeight: 900 }}
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

                        <div style={{ display: "grid", placeItems: "center", width: "100%", marginTop: -6 }}>
                            <button
                                type="button"
                                onClick={copyInviteByClick}
                                title="Klick → Join-Link kopieren"
                                style={{ border: "none", background: "transparent", cursor: isRunning ? "not-allowed" : "pointer", padding: 0, pointerEvents: "auto" }}
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
                                        backgroundSize: "200% 100%",
                                        WebkitBackgroundClip: "text",
                                        backgroundClip: "text",
                                        color: "transparent",
                                        animation: "kumpir-rainbow 3.4s linear infinite",
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
                      100% { background-position: 200% 50%; }
                    }
                  `}</style>
                        </div>
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
                                <div style={{ display: "flex", gap: 8 }}>
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
                </section>
            </div>
        </main>
    );
}