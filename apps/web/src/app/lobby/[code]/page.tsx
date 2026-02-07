// src/app/lobby/[code]/page.tsx
"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { getAppOrigin } from "@/lib/appOrigin";

type LobbyRow = {
    id: string;
    code: string;
    host_player_id: string | null; // uuid
};

type PlayerRow = {
    player_id: string; // uuid
    name: string;
    ready: boolean | null;
    joined_at?: string | null;
};

function readStoredPlayerId(): string | null {
    if (typeof window === "undefined") return null;
    // ✅ safest: localStorage first
    const a = localStorage.getItem("kumpir_player_id");
    if (a && a.length > 0) return a;
    // fallback (falls irgendwo noch sessionStorage genutzt wird)
    try {
        const b = sessionStorage.getItem("kumpir_player_id");
        return b && b.length > 0 ? b : null;
    } catch {
        return null;
    }
}

function readStoredName(): string | null {
    if (typeof window === "undefined") return null;
    const a = localStorage.getItem("kumpir_player_name");
    if (a && a.length > 0) return a;
    try {
        const b = sessionStorage.getItem("kumpir_player_name");
        return b && b.length > 0 ? b : null;
    } catch {
        return null;
    }
}

function fmtJoinLink(origin: string, code: string) {
    return `${origin}/join?code=${encodeURIComponent(code)}`;
}

function getErrorMessage(err: unknown): string {
    if (err instanceof Error) return err.message;
    if (typeof err === "object" && err !== null && "message" in err) {
        const m = (err as { message?: unknown }).message;
        if (typeof m === "string") return m;
    }
    return "Unbekannter Fehler.";
}

export default function LobbyPage() {
    const supabase = getSupabaseClient();
    const router = useRouter();
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const [mePlayerId, setMePlayerId] = useState<string | null>(null);
    const [meName, setMeName] = useState<string | null>(null);

    const [lobby, setLobby] = useState<LobbyRow | null>(null);
    const [players, setPlayers] = useState<PlayerRow[]>([]);
    const [loading, setLoading] = useState(true);
    const [err, setErr] = useState("");

    const [toast, setToast] = useState("");
    const [busyReady, setBusyReady] = useState(false);

    const autoStartedRef = useRef(false);

    /**
     * ✅ Safest Identity Sync:
     * - initial read
     * - listen to storage events (other tabs)
     * - also poll lightly (same tab storage has no event)
     * - BUT: do NOT overwrite with null once we already have a value
     *   (prevents "(du)" from flickering down)
     */
    useEffect(() => {
        const sync = () => {
            const pid = readStoredPlayerId();
            const nm = readStoredName();

            setMePlayerId((prev) => pid ?? prev);
            setMeName((prev) => nm ?? prev);
        };

        sync();

        const onStorage = (e: StorageEvent) => {
            if (e.key === "kumpir_player_id" || e.key === "kumpir_player_name") sync();
        };
        window.addEventListener("storage", onStorage);

        // same-tab: lightweight polling + focus/visibility
        const t = window.setInterval(sync, 500);
        const onFocus = () => sync();
        window.addEventListener("focus", onFocus);
        document.addEventListener("visibilitychange", onFocus);

        return () => {
            window.removeEventListener("storage", onStorage);
            window.removeEventListener("focus", onFocus);
            document.removeEventListener("visibilitychange", onFocus);
            window.clearInterval(t);
        };
    }, []);

    const amIHost = useMemo(() => {
        if (!mePlayerId || !lobby?.host_player_id) return false;
        return lobby.host_player_id === mePlayerId;
    }, [lobby?.host_player_id, mePlayerId]);

    const meReady = useMemo(() => {
        if (!mePlayerId) return false;
        const row = players.find((p) => p.player_id === mePlayerId);
        return !!row?.ready;
    }, [players, mePlayerId]);

    const allReady = useMemo(() => {
        if (players.length < 2) return false;
        return players.every((p) => !!p.ready);
    }, [players]);

    async function loadLobbyAndPlayers() {
        const lobbyRes = await supabase
            .from("lobbies")
            .select("id,code,host_player_id")
            .eq("code", code)
            .single();

        if (lobbyRes.error || !lobbyRes.data) {
            setErr(lobbyRes.error?.message || "Lobby nicht gefunden.");
            return;
        }

        const lobbyRow = lobbyRes.data as LobbyRow;
        setLobby(lobbyRow);

        const playersRes = await supabase
            .from("players")
            .select("player_id,name,ready,joined_at")
            .eq("lobby_id", lobbyRow.id)
            .order("joined_at", { ascending: true });

        if (playersRes.error) {
            setErr(playersRes.error.message || "Konnte Spieler nicht laden.");
            return;
        }

        const rows = (playersRes.data ?? []) as PlayerRow[];

        /**
         * ✅ Stable ordering:
         * - keep DB order, but if "me" exists, keep it pinned where it already is
         *   (prevents "(du) shifts down" on refresh)
         *
         * Simplest stable behavior: host stays in DB order; "(du)" just labels correct row.
         * The real cause of shifting was unstable mePlayerId; now fixed.
         */
        setPlayers(rows);
    }

    // ✅ Polling: only reads
    useEffect(() => {
        let alive = true;

        (async () => {
            setLoading(true);
            try {
                setErr("");
                await loadLobbyAndPlayers();
            } catch (e: unknown) {
                setErr(getErrorMessage(e));
            } finally {
                if (alive) setLoading(false);
            }
        })();

        const t = window.setInterval(() => loadLobbyAndPlayers(), 1200);
        return () => {
            alive = false;
            window.clearInterval(t);
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [code]);

    async function copyInviteByClick() {
        try {
            const origin = getAppOrigin();
            const link = fmtJoinLink(origin, code);

            await navigator.clipboard.writeText(link);
            setToast("✅ Link kopiert");
            window.setTimeout(() => setToast(""), 1200);
        } catch {
            setToast("⚠️ Kopieren nicht möglich");
            window.setTimeout(() => setToast(""), 1200);
        }
    }

    async function toggleReady() {
        // ✅ hard guard: must have uuid string
        if (!mePlayerId) {
            setErr("player_id fehlt. Bitte erneut über /join beitreten.");
            return;
        }
        if (!lobby?.id) {
            setErr("Lobby ist noch nicht geladen.");
            return;
        }
        if (busyReady) return;

        setErr("");
        setBusyReady(true);
        try {
            const { data, error } = await supabase.rpc("rpc_toggle_ready", {
                p_lobby_id: lobby.id,
                p_player_id: mePlayerId, // uuid string ok
            });

            if (error) {
                setErr(error.message || "Ready konnte nicht gesetzt werden.");
                return;
            }

            // optional: if RPC returns boolean you could optimistic update; safest is reload
            void data;

            await loadLobbyAndPlayers();
        } finally {
            setBusyReady(false);
        }
    }

    function startGame() {
        router.push(`/game/${code}`);
    }

    useEffect(() => {
        if (!amIHost) return;
        if (!allReady) return;
        if (autoStartedRef.current) return;

        autoStartedRef.current = true;
        const t = window.setTimeout(() => startGame(), 600);
        return () => window.clearTimeout(t);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [amIHost, allReady]);

    const meLabel = amIHost ? "👑 Host" : meName ? `👤 ${meName}` : "👤 Spieler";

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

                        <div className="pillChip" style={{ height: 34, display: "flex", alignItems: "center" }}>
                            {meLabel}
                        </div>
                    </div>

                    <div className="stepsWrap">
                        <div className="stepsBox">
                            <div className="stepsTitle">Spieler</div>

                            {err ? <p className="errorText">{err}</p> : null}

                            <div style={{ overflowX: "auto" }}>
                                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                                    <thead>
                                    <tr style={{ textAlign: "left", opacity: 0.75 }}>
                                        <th style={{ padding: "10px 8px" }}>#</th>
                                        <th style={{ padding: "10px 8px" }}>Name</th>
                                        <th style={{ padding: "10px 8px", textAlign: "right" }}>Zustand</th>
                                    </tr>
                                    </thead>

                                    <tbody>
                                    {loading && players.length === 0 ? (
                                        <tr>
                                            <td colSpan={3} style={{ padding: "12px 8px", opacity: 0.75 }}>
                                                Lädt…
                                            </td>
                                        </tr>
                                    ) : null}

                                    {players.map((p, idx) => {
                                        const isMe = !!mePlayerId && p.player_id === mePlayerId;
                                        const isHostRow = !!lobby?.host_player_id && p.player_id === lobby.host_player_id;

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
                                            </tr>
                                        );
                                    })}

                                    {!loading && players.length === 0 ? (
                                        <tr>
                                            <td colSpan={3} style={{ padding: "12px 8px", opacity: 0.75 }}>
                                                Noch niemand beigetreten.
                                            </td>
                                        </tr>
                                    ) : null}
                                    </tbody>
                                </table>
                            </div>

                            <div className="fieldHelp" style={{ marginTop: 10, opacity: 0.85 }}>
                                {amIHost ? (
                                    <>
                                        Das Spiel startet automatisch, sobald <b>alle</b> bereit sind.
                                    </>
                                ) : (
                                    <>
                                        Drück unten rechts <b>Bereit</b>. Das Spiel startet automatisch, sobald alle bereit sind.
                                    </>
                                )}
                            </div>

                            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", gap: 12, marginTop: 14 }}>
                                <Link href="/host" className="btn btnSecondary btnSmall">
                                    ← Neue Lobby
                                </Link>

                                <button
                                    type="button"
                                    onClick={toggleReady}
                                    disabled={busyReady || !mePlayerId}
                                    className={`btn btnXL ${busyReady ? "btnDisabled" : ""} ${meReady ? "btnReadyOff" : "btnReadyOn"}`}
                                >
                                    {busyReady ? "…" : meReady ? "⛔ Nicht bereit" : "✨ Bereit"}
                                </button>
                            </div>

                            {amIHost && allReady ? (
                                <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 10 }}>
                                    <button type="button" className="btn btnPrimary btnSmall btnGlow" onClick={startGame}>
                                        🚀 Spiel starten
                                    </button>
                                </div>
                            ) : null}
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}