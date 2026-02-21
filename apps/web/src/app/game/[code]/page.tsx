"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

import { GameBoard } from "@/components/game/GameBoard";
import { PlayerRing } from "@/components/game/PlayerRing";

import { passPotato } from "@/actions/passPotato";
import { tickGame } from "@/actions/tickGame";
import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";

type LobbyPhase = "lobby" | "topic_vote" | "countdown" | "running" | "finished" | string;

type LobbyState = {
    id: string;

    phase: LobbyPhase;
    holder_player_id: string | null;

    explode_at: string | null;
    run_started_at: string | null;
    last_activity_at: string | null;

    // Topic voting
    topic_a: string | null;
    topic_b: string | null;
    topic_selected: string | null;
    topic_vote_ends_at: string | null;

    // Countdown (synced)
    countdown_ends_at: string | null;
    countdown_started_at: string | null;

    // Tie visualization
    topic_tie_choices: number[] | null; // [1,2,3] subset
    topic_tie_pick: number | null; // 1|2|3
};

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

type VoteCounts = { a: number; b: number; r: number };

function getErrorMessage(e: unknown): string {
    if (e instanceof Error) return e.message;
    if (typeof e === "string") return e;
    try {
        return JSON.stringify(e);
    } catch {
        return "Unbekannter Fehler";
    }
}

function goLobby(code: string) {
    if (typeof window === "undefined") return;
    window.location.replace(`/lobby/${code}`);
}

function clamp(n: number, min: number, max: number) {
    return Math.max(min, Math.min(max, n));
}

function msUntil(ts: string | null): number | null {
    if (!ts) return null;
    const ms = Date.parse(ts);
    if (Number.isNaN(ms)) return null;
    return ms - Date.now();
}

export default function GamePage() {
    const supabase = getSupabaseClient();
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId } = usePlayerIdentity();

    const [lobby, setLobby] = useState<LobbyState | null>(null);
    const [players, setPlayers] = useState<Player[]>([]);
    const [fatalError, setFatalError] = useState<string>("");

    const inFlightRef = useRef(false);

    // Topic vote state
    const [voteCounts, setVoteCounts] = useState<VoteCounts>({ a: 0, b: 0, r: 0 });
    const [myVote, setMyVote] = useState<1 | 2 | 3 | null>(null);
    const [voteBusy, setVoteBusy] = useState(false);

    // Synced timers (display only)
    const [voteSecondsLeft, setVoteSecondsLeft] = useState<number | null>(null);
    const [countdownSecondsLeft, setCountdownSecondsLeft] = useState<number | null>(null);

    // Pass UX
    const [toast, setToast] = useState("");
    const [passBusy, setPassBusy] = useState(false);

    const showToast = useCallback((msg: string, ms = 1600) => {
        setToast(msg);
        window.setTimeout(() => setToast(""), ms);
    }, []);

    const meRow = useMemo(() => {
        if (!mePlayerId) return null;
        return players.find((p) => p.player_id === mePlayerId) ?? null;
    }, [players, mePlayerId]);

    const iAmEliminated = !!meRow && !meRow.is_alive;

    const isMeHolder = useMemo(() => {
        if (!mePlayerId || !lobby?.holder_player_id) return false;
        return lobby.holder_player_id === mePlayerId;
    }, [lobby?.holder_player_id, mePlayerId]);

    const holderName = useMemo(() => {
        if (!lobby?.holder_player_id) return "…";
        return players.find((p) => p.player_id === lobby.holder_player_id)?.name ?? "…";
    }, [players, lobby?.holder_player_id]);

    // -----------------------------
    // Poll loop (Lobby + Players + Votes)
    // -----------------------------
    useEffect(() => {
        let alive = true;

        const load = async () => {
            if (inFlightRef.current) return;
            inFlightRef.current = true;

            try {
                const lobbyRes = await supabase
                    .from("lobbies")
                    .select(
                        [
                            "id",
                            "phase",
                            "holder_player_id",
                            "explode_at",
                            "last_activity_at",
                            "run_started_at",
                            "topic_a",
                            "topic_b",
                            "topic_selected",
                            "topic_vote_ends_at",
                            "countdown_started_at",
                            "countdown_ends_at",
                            "topic_tie_choices",
                            "topic_tie_pick",
                        ].join(",")
                    )
                    .eq("code", code)
                    .single();

                if (!alive) return;

                if (lobbyRes.error || !lobbyRes.data) {
                    setFatalError(lobbyRes.error?.message ?? "Lobby konnte nicht geladen werden.");
                    return;
                }

                const nextLobby: LobbyState = {
                    id: lobbyRes.data.id,
                    phase: lobbyRes.data.phase,
                    holder_player_id: lobbyRes.data.holder_player_id ?? null,
                    explode_at: lobbyRes.data.explode_at ?? null,
                    last_activity_at: lobbyRes.data.last_activity_at ?? null,
                    run_started_at: lobbyRes.data.run_started_at ?? null,

                    topic_a: lobbyRes.data.topic_a ?? null,
                    topic_b: lobbyRes.data.topic_b ?? null,
                    topic_selected: lobbyRes.data.topic_selected ?? null,
                    topic_vote_ends_at: lobbyRes.data.topic_vote_ends_at ?? null,

                    countdown_started_at: lobbyRes.data.countdown_started_at ?? null,
                    countdown_ends_at: lobbyRes.data.countdown_ends_at ?? null,

                    topic_tie_choices: (lobbyRes.data.topic_tie_choices as number[] | null) ?? null,
                    topic_tie_pick: (lobbyRes.data.topic_tie_pick as number | null) ?? null,
                };

                setLobby(nextLobby);

                const playersRes = await supabase
                    .from("players")
                    .select("player_id,name,is_alive,status,seat_index")
                    .eq("lobby_id", nextLobby.id)
                    .eq("status", "active")
                    .order("seat_index", { ascending: true });

                if (!alive) return;

                if (playersRes.error || !playersRes.data) {
                    setFatalError(playersRes.error?.message ?? "Spieler konnten nicht geladen werden.");
                    return;
                }

                const nextPlayers = playersRes.data as unknown as Player[];
                setPlayers(nextPlayers);
                setFatalError("");

                // ---- Topic vote counts (only when needed)
                if (nextLobby.phase === "topic_vote") {
                    const votesRes = await supabase
                        .from("topic_votes")
                        .select("choice,player_id")
                        .eq("lobby_id", nextLobby.id);

                    if (!alive) return;

                    if (!votesRes.error && votesRes.data) {
                        let a = 0,
                            b = 0,
                            r = 0;

                        let mine: 1 | 2 | 3 | null = null;
                        for (const row of votesRes.data as Array<{ choice: number; player_id: string }>) {
                            if (row.choice === 1) a++;
                            else if (row.choice === 2) b++;
                            else if (row.choice === 3) r++;

                            if (mePlayerId && row.player_id === mePlayerId) {
                                if (row.choice === 1 || row.choice === 2 || row.choice === 3) mine = row.choice as 1 | 2 | 3;
                            }
                        }
                        setVoteCounts({ a, b, r });
                        setMyVote(mine);
                    }
                } else {
                    // cleanup
                    setVoteCounts({ a: 0, b: 0, r: 0 });
                    setMyVote(null);
                }

                // ---- Best-effort “advance” calls (prevents freeze)
                // 1) running: tickGame due
                if (mePlayerId && nextLobby.phase === "running" && nextLobby.explode_at) {
                    const meAlive = nextPlayers.find((p) => p.player_id === mePlayerId)?.is_alive ?? true;
                    const explodeMs = Date.parse(nextLobby.explode_at);
                    const due = !Number.isNaN(explodeMs) && Date.now() >= explodeMs - 150;
                    if (meAlive && due) void tickGame(code).catch(() => {});
                }

                // 2) topic_vote: finalize when due (fallback if nobody triggers early finish)
                if (nextLobby.phase === "topic_vote" && nextLobby.topic_vote_ends_at) {
                    const dueMs = msUntil(nextLobby.topic_vote_ends_at);
                    if (dueMs !== null && dueMs <= 0) {
                        void supabase.rpc("rpc_finalize_topic_vote", { p_lobby_id: nextLobby.id }).catch(() => {});
                    }
                }

                // 3) countdown: advance to running when due
                if (nextLobby.phase === "countdown" && nextLobby.countdown_ends_at) {
                    const dueMs = msUntil(nextLobby.countdown_ends_at);
                    if (dueMs !== null && dueMs <= 0) {
                        void supabase.rpc("rpc_advance_from_countdown", { p_lobby_id: nextLobby.id }).catch(() => {});
                    }
                }
            } finally {
                inFlightRef.current = false;
            }
        };

        void load();
        const t = window.setInterval(() => void load(), 650);

        return () => {
            alive = false;
            window.clearInterval(t);
        };
    }, [code, supabase, mePlayerId]);

    // -----------------------------
    // Synced timers (vote + countdown)
    // -----------------------------
    useEffect(() => {
        let raf = 0;

        const step = () => {
            if (!lobby) {
                setVoteSecondsLeft(null);
                setCountdownSecondsLeft(null);
                raf = window.requestAnimationFrame(step);
                return;
            }

            if (lobby.phase === "topic_vote") {
                const ms = msUntil(lobby.topic_vote_ends_at);
                if (ms === null) setVoteSecondsLeft(null);
                else setVoteSecondsLeft(clamp(Math.ceil(ms / 1000), 0, 99));
            } else {
                setVoteSecondsLeft(null);
            }

            if (lobby.phase === "countdown") {
                const ms = msUntil(lobby.countdown_ends_at);
                if (ms === null) setCountdownSecondsLeft(null);
                else setCountdownSecondsLeft(clamp(Math.ceil(ms / 1000), 0, 10));
            } else {
                setCountdownSecondsLeft(null);
            }

            raf = window.requestAnimationFrame(step);
        };

        raf = window.requestAnimationFrame(step);
        return () => {
            if (raf) window.cancelAnimationFrame(raf);
        };
    }, [lobby]);

    // -----------------------------
    // Vote action
    // -----------------------------
    const vote = useCallback(
        async (choice: 1 | 2 | 3) => {
            if (!mePlayerId) return showToast("⚠️ Keine Player-ID", 1800);
            if (!lobby) return;
            if (lobby.phase !== "topic_vote") return;
            if (voteBusy) return;

            setVoteBusy(true);
            try {
                await supabase.rpc("rpc_vote_topic", {
                    p_lobby_id: lobby.id,
                    p_player_id: mePlayerId,
                    p_choice: choice,
                });

                setMyVote(choice);
                showToast("✅ Vote gespeichert", 900);
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2400);
            } finally {
                setVoteBusy(false);
            }
        },
        [mePlayerId, lobby, voteBusy, supabase, showToast]
    );

    // -----------------------------
    // PASS handler
    // -----------------------------
    const handlePass = useCallback(async () => {
        if (!mePlayerId) return showToast("⚠️ Keine Player-ID", 1800);
        if (!lobby || lobby.phase !== "running") return showToast("⏳ Noch nicht gestartet", 1400);
        if (iAmEliminated) return showToast("💀 Du bist raus", 1400);
        if (!isMeHolder) return showToast("🙅 Du hast die Kartoffel nicht", 1400);
        if (passBusy) return;

        setPassBusy(true);
        try {
            await passPotato(code, mePlayerId);
            showToast("✅ Weitergegeben", 900);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2400);
        } finally {
            setPassBusy(false);
        }
    }, [mePlayerId, lobby, iAmEliminated, isMeHolder, passBusy, code, showToast]);

    // Spacebar pass (nur running)
    useEffect(() => {
        const onKeyDown = (ev: KeyboardEvent) => {
            if (ev.code !== "Space") return;
            if (!lobby || lobby.phase !== "running") return;
            ev.preventDefault();
            void handlePass();
        };

        window.addEventListener("keydown", onKeyDown, { passive: false });
        return () => window.removeEventListener("keydown", onKeyDown);
    }, [handlePass, lobby]);

    // -----------------------------
    // UI: fatal / loading
    // -----------------------------
    if (fatalError) {
        return (
            <main style={{ minHeight: "100vh", display: "grid", placeItems: "center", padding: 24 }}>
                <div style={{ width: "min(720px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontWeight: 950, fontSize: 22 }}>⚠️ Spiel konnte nicht geladen werden</div>
                    <div style={{ marginTop: 10, opacity: 0.8 }}>{fatalError}</div>
                    <div style={{ marginTop: 18 }}>
                        <button className="btn btnPrimary btnXL" onClick={() => goLobby(code)} type="button">
                            Zurück zur Lobby
                        </button>
                    </div>
                </div>
            </main>
        );
    }

    if (!lobby) return <div className="p-6 opacity-70">Lade Spiel…</div>;

    // -----------------------------
    // Phase: topic_vote
    // -----------------------------
    if (lobby.phase === "topic_vote") {
        const a = lobby.topic_a ?? "…";
        const b = lobby.topic_b ?? "…";

        const totalPlayers = players.length;
        const votedPlayers = voteCounts.a + voteCounts.b + voteCounts.r;

        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(243,168,59,0.45) 0%, rgba(192,106,0,0.82) 80%)",
                }}
            >
                <div style={{ width: "min(900px, 96vw)" }}>
                    <div style={{ textAlign: "center" }}>
                        <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>THEMA VOTING</div>

                        <div style={{ fontSize: "clamp(26px, 4vw, 44px)", fontWeight: 950, marginTop: 10 }}>
                            Wählt das Thema
                        </div>

                        <div style={{ marginTop: 10, opacity: 0.8, fontWeight: 750 }}>
                            Zeit: <b>{voteSecondsLeft ?? 15}s</b> · Votes: <b>{votedPlayers}</b> / <b>{totalPlayers}</b>
                        </div>

                        <div style={{ marginTop: 14, display: "grid", gap: 12 }}>
                            <button
                                className={`btn btnXL ${myVote === 1 ? "btnPrimary" : "btnSecondary"}`}
                                disabled={voteBusy || !mePlayerId}
                                onClick={() => void vote(1)}
                                type="button"
                                style={{ width: "100%" }}
                            >
                                ① {a} <span style={{ opacity: 0.75, marginLeft: 10 }}>({voteCounts.a})</span>
                            </button>

                            <button
                                className={`btn btnXL ${myVote === 2 ? "btnPrimary" : "btnSecondary"}`}
                                disabled={voteBusy || !mePlayerId}
                                onClick={() => void vote(2)}
                                type="button"
                                style={{ width: "100%" }}
                            >
                                ② {b} <span style={{ opacity: 0.75, marginLeft: 10 }}>({voteCounts.b})</span>
                            </button>

                            <button
                                className={`btn btnXL ${myVote === 3 ? "btnPrimary" : "btnSecondary"}`}
                                disabled={voteBusy || !mePlayerId}
                                onClick={() => void vote(3)}
                                type="button"
                                style={{ width: "100%" }}
                            >
                                ③ 🎲 Zufällig <span style={{ opacity: 0.75, marginLeft: 10 }}>({voteCounts.r})</span>
                            </button>
                        </div>

                        <div style={{ marginTop: 14, opacity: 0.78, fontWeight: 750 }}>
                            Wenn alle gewählt haben, geht’s sofort weiter.
                        </div>

                        <div style={{ marginTop: 18, display: "flex", justifyContent: "center", gap: 12 }}>
                            <button className="btn btnSecondary btnXL" onClick={() => goLobby(code)} type="button">
                                Zur Lobby
                            </button>
                        </div>

                        {toast ? <div style={{ marginTop: 18, fontWeight: 900, opacity: 0.92 }}>{toast}</div> : null}
                    </div>
                </div>
            </main>
        );
    }

    // -----------------------------
    // Phase: countdown (synced)
    // -----------------------------
    if (lobby.phase === "countdown") {
        const selected = lobby.topic_selected ?? lobby.topic_a ?? "…";

        const tie = lobby.topic_tie_choices && lobby.topic_tie_choices.length > 1;
        const tieChoices = lobby.topic_tie_choices ?? [];
        const pick = lobby.topic_tie_pick;

        const labelForChoice = (c: number) => {
            if (c === 1) return `① ${lobby.topic_a ?? "…"} `;
            if (c === 2) return `② ${lobby.topic_b ?? "…"} `;
            if (c === 3) return `③ 🎲 Zufällig `;
            return String(c);
        };

        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(52,199,89,0.22) 0%, rgba(0,120,45,0.68) 80%)",
                }}
            >
                <div style={{ width: "min(920px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>THEMA GEWÄHLT</div>

                    <div style={{ fontSize: "clamp(28px, 4.2vw, 52px)", fontWeight: 950, marginTop: 12 }}>
                        {selected}
                    </div>

                    {tie ? (
                        <div style={{ marginTop: 12, opacity: 0.85, fontWeight: 800 }}>
                            Tie zwischen:{" "}
                            <span style={{ opacity: 0.95 }}>
                {tieChoices.map((c) => labelForChoice(c)).join(" · ")}
              </span>
                            <div style={{ marginTop: 6, opacity: 0.9 }}>
                                Zufällig gewählt: <b>{pick ? labelForChoice(pick) : "…"}</b>
                            </div>
                        </div>
                    ) : (
                        <div style={{ marginTop: 12, opacity: 0.82, fontWeight: 750 }}>Jetzt kurz Thema im Kopf: sag gleich was dazu.</div>
                    )}

                    <div style={{ marginTop: 22, fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>START IN</div>
                    <div
                        style={{
                            marginTop: 10,
                            fontSize: "clamp(80px, 10vw, 140px)",
                            fontWeight: 950,
                            letterSpacing: 2,
                            textShadow: "0 18px 70px rgba(0,0,0,0.35)",
                        }}
                    >
                        {Math.max(0, countdownSecondsLeft ?? 5)}
                    </div>

                    <div style={{ marginTop: 14, display: "flex", justifyContent: "center", gap: 12 }}>
                        <button className="btn btnSecondary btnXL" onClick={() => goLobby(code)} type="button">
                            Zur Lobby
                        </button>
                    </div>

                    {toast ? <div style={{ marginTop: 18, fontWeight: 900, opacity: 0.92 }}>{toast}</div> : null}
                </div>
            </main>
        );
    }

    // -----------------------------
    // Phase: finished
    // -----------------------------
    if (lobby.phase === "finished") {
        const winner = lobby.holder_player_id
            ? players.find((p) => p.player_id === lobby.holder_player_id)?.name ?? "Unbekannt"
            : "Unbekannt";

        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(243,168,59,0.55) 0%, rgba(192,106,0,0.88) 80%)",
                }}
            >
                <div style={{ textAlign: "center", width: "min(900px, 96vw)" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>SPIEL BEENDET</div>
                    <div style={{ fontSize: "clamp(44px, 6vw, 82px)", fontWeight: 950, marginTop: 14 }}>🏆 {winner}</div>
                    <div style={{ marginTop: 12, fontSize: 14, fontWeight: 700, opacity: 0.75 }}>
                        {iAmEliminated ? "Du bist raus – aber du konntest zuschauen." : "GG."}
                    </div>
                    <div style={{ display: "flex", gap: 12, justifyContent: "center", marginTop: 22 }}>
                        <button className="btn btnPrimary btnXL" onClick={() => goLobby(code)} type="button">
                            Zur Lobby
                        </button>
                        <button className="btn btnSecondary btnXL" onClick={() => (window.location.href = "/")} type="button">
                            Hauptmenü
                        </button>
                    </div>
                </div>
            </main>
        );
    }

    // -----------------------------
    // Phase: running (Main board + ring + backgrounds)
    // -----------------------------
    if (lobby.phase !== "running") {
        // fallback (z.B. lobby/round_end)
        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(243,168,59,0.35) 0%, rgba(192,106,0,0.70) 80%)",
                }}
            >
                <div style={{ width: "min(820px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>WARTEN</div>
                    <div style={{ fontSize: "clamp(28px, 4vw, 46px)", fontWeight: 950, marginTop: 12 }}>⏳ Warten…</div>
                    <div style={{ marginTop: 10, opacity: 0.78, fontWeight: 700 }}>Der Host startet gleich das Spiel.</div>
                    <div style={{ display: "flex", justifyContent: "center", gap: 12, marginTop: 22 }}>
                        <button className="btn btnSecondary btnXL" onClick={() => goLobby(code)} type="button">
                            Zur Lobby
                        </button>
                    </div>
                </div>
            </main>
        );
    }

    const runningBg = isMeHolder
        ? "radial-gradient(circle at 50% 35%, rgba(255,120,80,0.55) 0%, rgba(143,15,15,0.96) 72%)"
        : "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.08) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(52,199,89,0.26) 0%, rgba(0,130,60,0.78) 80%)";

    return (
        <main
            style={{
                minHeight: "100vh",
                width: "100vw",
                position: "relative",
                overflow: "hidden",
                background: runningBg,
            }}
        >
            {/* Holder pulse */}
            {isMeHolder ? <div className="holderPulseLayer" aria-hidden /> : null}

            {/* Toast overlay */}
            {toast ? (
                <div
                    style={{
                        position: "fixed",
                        left: "50%",
                        bottom: 22,
                        transform: "translateX(-50%)",
                        zIndex: 9999,
                        padding: "10px 14px",
                        borderRadius: 999,
                        background: "rgba(0,0,0,0.55)",
                        border: "1px solid rgba(255,255,255,0.10)",
                        fontWeight: 900,
                        backdropFilter: "blur(10px)",
                        WebkitBackdropFilter: "blur(10px)",
                    }}
                >
                    {toast}
                </div>
            ) : null}

            {/* Ring overlay */}
            <PlayerRing players={players} holderPlayerId={lobby.holder_player_id} mePlayerId={mePlayerId} />

            {/* Existing board (pass action stays) */}
            <GameBoard holderPlayerId={lobby.holder_player_id} players={players} mePlayerId={mePlayerId} onPass={handlePass} />

            <style>{`
        @keyframes holderPulse {
          0% { transform: scale(1); opacity: .55; }
          50% { transform: scale(1.03); opacity: .90; }
          100% { transform: scale(1); opacity: .55; }
        }
        .holderPulseLayer{
          position:absolute;
          inset:-40px;
          background: radial-gradient(circle at 50% 40%, rgba(255,90,90,.62), rgba(143,15,15,.95));
          filter: blur(18px);
          animation: holderPulse 1.2s ease-in-out infinite;
          pointer-events:none;
          z-index: 0;
        }
      `}</style>
        </main>
    );
}