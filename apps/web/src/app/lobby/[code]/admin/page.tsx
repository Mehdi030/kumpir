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

const GAME_PHASES = new Set(["topic_vote", "countdown", "running"]);

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
                    <Link href="/host" className="btn btnSecondary btnSmall" style={{ marginTop: 12 }}>
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
                            <div className="stepsTitle">Spieler verwalten</div>

                            <div style={{ overflowX: "auto" }}>
                                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                                    <thead>
                                        <tr style={{ textAlign: "left", opacity: 0.75 }}>
                                            <th style={{ padding: "10px 8px" }}>#</th>
                                            <th style={{ padding: "10px 8px" }}>Name</th>
                                            <th style={{ padding: "10px 8px" }}>Status</th>
                                            <th style={{ padding: "10px 8px", textAlign: "right" }}>Aktionen</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {players.map((p, idx) => {
                                            const isMe = !!mePlayerId && p.player_id === mePlayerId;
                                            const isHostRow = !!lobby.host_player_id && p.player_id === lobby.host_player_id;
                                            const rowBusy = busyTarget === p.player_id && pending;

                                            return (
                                                <tr
                                                    key={p.player_id}
                                                    style={{
                                                        borderTop: "1px solid rgba(255,255,255,0.08)",
                                                        background: isHostRow ? "rgba(255,255,255,0.06)" : "transparent",
                                                    }}
                                                >
                                                    <td style={{ padding: "10px 8px" }}>{idx + 1}</td>
                                                    <td style={{ padding: "10px 8px", fontWeight: 900 }}>
                                                        {p.name}
                                                        {isMe ? <span style={{ opacity: 0.6 }}> (du)</span> : null}
                                                        {isHostRow ? <span style={{ marginLeft: 8 }}>👑</span> : null}
                                                    </td>
                                                    <td style={{ padding: "10px 8px", opacity: 0.85 }}>{p.ready ? "✅ Bereit" : "⏳ nicht bereit"}</td>
                                                    <td style={{ padding: "10px 8px", textAlign: "right" }}>
                                                        <div style={{ display: "inline-flex", gap: 6 }}>
                                                            {!isHostRow ? (
                                                                <button
                                                                    type="button"
                                                                    className="btn btnSecondary btnSmall"
                                                                    disabled={pending}
                                                                    onClick={() => onTransfer(p.player_id, p.name)}
                                                                    title="Host übertragen"
                                                                >
                                                                    {rowBusy ? <Spinner size={14} /> : "👑 Host"}
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
                                                                    {rowBusy ? <Spinner size={14} /> : "👢 Kick"}
                                                                </button>
                                                            ) : null}
                                                        </div>
                                                    </td>
                                                </tr>
                                            );
                                        })}
                                        {players.length === 0 ? (
                                            <tr>
                                                <td colSpan={4} style={{ padding: "12px 8px", opacity: 0.75 }}>
                                                    Noch niemand beigetreten.
                                                </td>
                                            </tr>
                                        ) : null}
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>

                    <ToastStack toasts={toasts} />
                </section>
            </div>
        </main>
    );
}
