"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

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
    topic_tie_choices: number[] | null;
    topic_tie_pick: number | null;
};

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
    ready?: boolean;
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

    // Prevent spamming finalize/advance
    const finalizeInFlightRef = useRef(false);
    const advanceInFlightRef = useRef(false);

    // Pass UX
    const [toast, setToast] = useState("");
    const [passBusy, setPassBusy] = useState(false);

    const [reduceMotion, setReduceMotion] = useState(false);

    useEffect(() => {
        if (typeof window === "undefined") return;
        const mq = window.matchMedia?.("(prefers-reduced-motion: reduce)");
        const apply = () => setReduceMotion(!!mq?.matches);
        apply();
        mq?.addEventListener?.("change", apply);
        return () => mq?.removeEventListener?.("change", apply);
    }, []);

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

    const selectedTopic = useMemo(() => {
        return lobby?.topic_selected ?? lobby?.topic_a ?? "…";
    }, [lobby?.topic_selected, lobby?.topic_a]);

    // Winner choice (for result animation)
    const winnerChoice = useMemo<1 | 2 | 3 | null>(() => {
        if (!lobby) return null;

        const pick = lobby.topic_tie_pick;
        if (pick === 1 || pick === 2 || pick === 3) return pick;

        if (!lobby.topic_selected) return null;
        if (lobby.topic_selected === lobby.topic_a) return 1;
        if (lobby.topic_selected === lobby.topic_b) return 2;
        return 3; // fallback (random)
    }, [lobby]);

    const totalPlayers = players.length;
    const votedPlayers = voteCounts.a + voteCounts.b + voteCounts.r;
    const allVoted = totalPlayers > 0 && votedPlayers >= totalPlayers;

    // -----------------------------
    // Best-effort RPC wrappers (NO silent swallow)
    // -----------------------------
    const rpcFinalizeTopicVote = useCallback(
        async (lobbyId: string) => {
            const { error } = await supabase.rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
            if (error) {
                console.error("rpc_finalize_topic_vote failed:", error);
                // keep UI running; show toast for visibility
                showToast(`❌ Finalize: ${error.message}`, 2400);
                throw new Error(error.message);
            }
        },
        [supabase, showToast]
    );

    const rpcAdvanceFromCountdown = useCallback(
        async (lobbyId: string) => {
            const { error } = await supabase.rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });
            if (error) {
                console.error("rpc_advance_from_countdown failed:", error);
                showToast(`❌ Advance: ${error.message}`, 2400);
                throw new Error(error.message);
            }
        },
        [supabase, showToast]
    );

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
                    .select("player_id,name,is_alive,status,seat_index,ready")
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
                    const votesRes = await supabase.from("topic_votes").select("choice,player_id").eq("lobby_id", nextLobby.id);
                    if (!alive) return;

                    if (votesRes.error) {
                        // This is where you’d see the "updated_at does not exist" indirectly only if you were writing.
                        // But if SELECT fails, show a fatal.
                        console.error("topic_votes select failed:", votesRes.error);
                        showToast(`❌ Votes laden: ${votesRes.error.message}`, 2400);
                    } else if (votesRes.data) {
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
                    setVoteCounts({ a: 0, b: 0, r: 0 });
                    setMyVote(null);
                }

                // ---- Best-effort “advance” calls (with visibility)

                // 1) running: tickGame due
                if (mePlayerId && nextLobby.phase === "running" && nextLobby.explode_at) {
                    const meAlive = nextPlayers.find((p) => p.player_id === mePlayerId)?.is_alive ?? true;
                    const explodeMs = Date.parse(nextLobby.explode_at);
                    const due = !Number.isNaN(explodeMs) && Date.now() >= explodeMs - 150;
                    if (meAlive && due) void tickGame(code).catch((e) => console.error("tickGame failed:", e));
                }

                // 2) topic_vote: finalize when due (timer)
                if (nextLobby.phase === "topic_vote" && nextLobby.topic_vote_ends_at) {
                    const dueMs = msUntil(nextLobby.topic_vote_ends_at);
                    if (dueMs !== null && dueMs <= 0 && !finalizeInFlightRef.current) {
                        finalizeInFlightRef.current = true;
                        void rpcFinalizeTopicVote(nextLobby.id).finally(() => {
                            finalizeInFlightRef.current = false;
                        });
                    }
                }

                // 3) countdown: advance to running when due
                if (nextLobby.phase === "countdown" && nextLobby.countdown_ends_at) {
                    const dueMs = msUntil(nextLobby.countdown_ends_at);
                    if (dueMs !== null && dueMs <= 0 && !advanceInFlightRef.current) {
                        advanceInFlightRef.current = true;
                        void rpcAdvanceFromCountdown(nextLobby.id).finally(() => {
                            advanceInFlightRef.current = false;
                        });
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
    }, [code, supabase, mePlayerId, rpcFinalizeTopicVote, rpcAdvanceFromCountdown, showToast]);

    // -----------------------------
    // EARLY FINISH: when all voted -> finalize immediately
    // -----------------------------
    useEffect(() => {
        if (!lobby) return;
        if (lobby.phase !== "topic_vote") return;
        if (!allVoted) return;
        if (finalizeInFlightRef.current) return;

        finalizeInFlightRef.current = true;
        void rpcFinalizeTopicVote(lobby.id).finally(() => {
            finalizeInFlightRef.current = false;
        });
    }, [allVoted, lobby, rpcFinalizeTopicVote]);

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
    // Vote action (shows real DB error)
    // -----------------------------
    const vote = useCallback(
        async (choice: 1 | 2 | 3) => {
            if (!mePlayerId) return showToast("⚠️ Keine Player-ID", 1800);
            if (!lobby) return;
            if (lobby.phase !== "topic_vote") return;
            if (voteBusy) return;

            setVoteBusy(true);
            try {
                const { error } = await supabase.rpc("rpc_vote_topic", {
                    p_lobby_id: lobby.id,
                    p_player_id: mePlayerId,
                    p_choice: choice,
                });

                if (error) {
                    // This is exactly where you will see: updated_at does not exist
                    console.error("rpc_vote_topic failed:", error);
                    throw new Error(error.message);
                }

                setMyVote(choice);
                showToast("✅ Vote gespeichert", 900);
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2600);
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

    // Labels
    const aLabel = lobby.topic_a ?? "…";
    const bLabel = lobby.topic_b ?? "…";
    const rLabel = "Zufällig";

    // =========================================================
    // PHASE: TOPIC VOTE (NO PARALLAX SHIFT, BIGGER CARDS, ONLY HOVER SCALE)
    // =========================================================
    if (lobby.phase === "topic_vote") {
        const timeLeft = voteSecondsLeft ?? 15;

        // UI duration used for progress bar. If your DB duration differs, set it accordingly.
        const duration = 15;
        const progress = clamp(timeLeft / duration, 0, 1);

        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    position: "relative",
                    overflow: "hidden",
                    background:
                        "radial-gradient(circle at 25% 15%, rgba(255,255,255,0.16) 0%, rgba(0,0,0,0) 55%)," +
                        "radial-gradient(circle at 80% 10%, rgba(34,211,238,0.10) 0%, rgba(0,0,0,0) 58%)," +
                        "radial-gradient(circle at 50% 90%, rgba(255,214,10,0.55) 0%, rgba(240,138,26,0.60) 45%, rgba(197,58,18,0.92) 78%, rgba(143,15,15,0.98) 100%)",
                }}
            >
                <div className="grain" aria-hidden />
                <div className="orbs" aria-hidden>
                    <span className="orb o1" />
                    <span className="orb o2" />
                    <span className="orb o3" />
                </div>

                <div style={{ width: "min(1160px, 96vw)", position: "relative", zIndex: 2 }}>
                    <div style={{ textAlign: "center" }}>
                        <div className="kicker">THEMA VOTING</div>

                        <div className="headline">
                            Wählt das Thema
                            <span className="headlineGlow" aria-hidden />
                        </div>

                        <div className="topicGrid">
                            <button
                                type="button"
                                onClick={() => void vote(1)}
                                disabled={voteBusy || !mePlayerId}
                                className={`glassCard ${myVote === 1 ? "active" : ""}`}
                            >
                                <div className="glassShine" aria-hidden />
                                <div className="cardTop">
                                    <span className="chip">①</span>
                                    <span className="micro">Thema A</span>
                                </div>
                                <div className="cardTitle">{aLabel}</div>
                                <div className="cardHint">Tippe zum Voten</div>
                            </button>

                            <button
                                type="button"
                                onClick={() => void vote(2)}
                                disabled={voteBusy || !mePlayerId}
                                className={`glassCard ${myVote === 2 ? "active" : ""}`}
                            >
                                <div className="glassShine" aria-hidden />
                                <div className="cardTop">
                                    <span className="chip">②</span>
                                    <span className="micro">Thema B</span>
                                </div>
                                <div className="cardTitle">{bLabel}</div>
                                <div className="cardHint">Tippe zum Voten</div>
                            </button>

                            <button
                                type="button"
                                onClick={() => void vote(3)}
                                disabled={voteBusy || !mePlayerId}
                                className={`glassCard ${myVote === 3 ? "active" : ""}`}
                            >
                                <div className="glassShine" aria-hidden />
                                <div className="cardTop">
                                    <span className="chip">🎲</span>
                                    <span className="micro">Random</span>
                                </div>
                                <div className="cardTitle">{rLabel}</div>
                                <div className="cardHint">Überraschen lassen</div>
                            </button>
                        </div>

                        {/* Status line UNDER the cards */}
                        <div className="statusLine">
                            {allVoted ? "✅ Alle haben gewählt – wird ausgewertet…" : "Wählt schnell – bei allen Votes geht’s sofort weiter."}
                        </div>

                        {toast ? <div className="toastInline">{toast}</div> : null}
                    </div>
                </div>

                {/* Bottom Countdown only */}
                <div className="bottomBar" style={{ zIndex: 50 }}>
                    <div className="bottomInner">
                        <div className="bottomLeft">
                            <div className="brandMark">🥔</div>
                            <div className="bottomText">
                                <div className="bottomTitle">Countdown</div>
                                <div className="bottomSub">{myVote ? "Dein Vote ist gesetzt." : "Tippe auf ein Thema."}</div>
                            </div>
                        </div>

                        <div className="barWrap" aria-hidden>
                            <div className="barTrack">
                                <div
                                    className="barFill"
                                    style={{
                                        width: `${Math.round(progress * 100)}%`,
                                        transition: reduceMotion ? "none" : "width 220ms linear",
                                    }}
                                />
                            </div>
                            <div className="barGlow" />
                        </div>

                        <div className="timeBox" aria-label="Sekunden verbleibend">
                            {timeLeft}s
                        </div>
                    </div>
                </div>

                <style>{`
          .kicker{
            font-size: 12px;
            font-weight: 950;
            letter-spacing: 2.2px;
            opacity: .78;
            text-transform: uppercase;
            animation: ${reduceMotion ? "none" : "fadeUp 700ms cubic-bezier(.2,.9,.2,1) both"};
          }
          .headline{
            margin-top: 10px;
            font-size: clamp(36px, 4.8vw, 70px);
            font-weight: 1000;
            letter-spacing: -0.6px;
            position: relative;
            display: inline-block;
            text-shadow: 0 24px 80px rgba(0,0,0,0.35);
            animation: ${reduceMotion ? "none" : "heroIn 900ms cubic-bezier(.16,1,.3,1) both"};
          }
          .headlineGlow{
            position:absolute;
            inset:-30px -60px;
            background: radial-gradient(circle at 40% 35%, rgba(255,214,10,0.25), rgba(255,149,0,0.18), rgba(255,45,85,0.06), transparent 70%);
            filter: blur(18px);
            opacity: .9;
            pointer-events:none;
            animation: ${reduceMotion ? "none" : "glowFloat 4.2s ease-in-out infinite"};
          }

          .topicGrid{
            margin-top: 24px;
            display:grid;
            grid-template-columns: repeat(3, minmax(0, 1fr));
            gap: 18px;
          }

          /* BIGGER 3D glass cards (no position shift on hover) */
          .glassCard{
            position:relative;
            width:100%;
            border-radius: 38px;
            padding: 24px 22px 22px;
            min-height: 260px;
            text-align:left;
            cursor:pointer;
            border: 1px solid rgba(255,255,255,0.18);
            background:
              linear-gradient(180deg, rgba(255,255,255,0.14), rgba(255,255,255,0.06)),
              radial-gradient(circle at 30% 20%, rgba(255,214,10,0.14), rgba(255,149,0,0.08), rgba(0,0,0,0.16) 70%);
            backdrop-filter: blur(16px) saturate(140%);
            -webkit-backdrop-filter: blur(16px) saturate(140%);
            box-shadow:
              0 18px 70px rgba(0,0,0,0.28),
              inset 0 1px 0 rgba(255,255,255,0.20);
            overflow:hidden;
            transform: translateZ(0);
            transition: transform .22s cubic-bezier(.2,1,.2,1), box-shadow .22s ease, border-color .22s ease, filter .22s ease;
            animation: ${reduceMotion ? "none" : "cardIn 900ms cubic-bezier(.16,1,.3,1) both"};
          }
          .glassCard:nth-child(2){ animation-delay: ${reduceMotion ? "0ms" : "70ms"}; }
          .glassCard:nth-child(3){ animation-delay: ${reduceMotion ? "0ms" : "140ms"}; }

          /* ONLY scale on hover (no translate/shift) */
          .glassCard:hover{
            transform: scale(1.035);
            border-color: rgba(255,255,255,0.30);
            box-shadow:
              0 26px 90px rgba(0,0,0,0.34),
              inset 0 1px 0 rgba(255,255,255,0.22);
            filter: brightness(1.03);
          }
          .glassCard:active{
            transform: scale(1.015);
          }
          .glassCard:disabled{
            opacity: .78;
            cursor:not-allowed;
            transform:none;
            filter:none;
          }

          .glassShine{
            position:absolute;
            inset:-120px;
            background:
              radial-gradient(circle at 20% 20%, rgba(255,255,255,0.24), rgba(255,255,255,0.06), transparent 60%);
            opacity:.75;
            filter: blur(18px);
            pointer-events:none;
            animation: ${reduceMotion ? "none" : "shineSweep 5.2s ease-in-out infinite"};
          }

          .cardTop{
            display:flex;
            justify-content:space-between;
            align-items:center;
            gap: 10px;
            position:relative;
            z-index:2;
          }
          .chip{
            display:inline-flex;
            align-items:center;
            justify-content:center;
            height: 38px;
            padding: 0 14px;
            border-radius: 999px;
            font-weight: 1000;
            background: rgba(0,0,0,0.18);
            border: 1px solid rgba(255,255,255,0.16);
            box-shadow: inset 0 1px 0 rgba(255,255,255,0.12);
          }
          .micro{
            font-size: 12px;
            font-weight: 950;
            letter-spacing: 1.2px;
            opacity:.78;
            text-transform: uppercase;
          }
          .cardTitle{
            margin-top: 20px;
            font-size: clamp(24px, 2.8vw, 40px);
            font-weight: 1000;
            letter-spacing: -0.2px;
            position:relative;
            z-index:2;
            text-shadow: 0 18px 60px rgba(0,0,0,0.26);
          }
          .cardHint{
            margin-top: 12px;
            font-size: 13px;
            font-weight: 900;
            opacity: .78;
            position:relative;
            z-index:2;
          }

          .glassCard.active{
            border-color: rgba(255,255,255,0.44);
            background:
              radial-gradient(circle at 20% 20%, rgba(255,255,255,0.18), rgba(0,0,0,0.10) 55%),
              linear-gradient(135deg, rgba(255,214,10,0.28), rgba(255,149,0,0.22), rgba(255,45,85,0.12));
            box-shadow:
              0 30px 110px rgba(0,0,0,0.40),
              0 0 0 1px rgba(255,255,255,0.06) inset;
            animation: ${reduceMotion ? "none" : "selectedBreath 1.05s ease-in-out infinite"};
          }

          .statusLine{
            margin-top: 14px;
            font-weight: 900;
            opacity: .86;
            font-size: 13px;
            animation: ${reduceMotion ? "none" : "fadeUp 520ms ease both"};
          }

          .toastInline{
            margin-top: 14px;
            font-weight: 950;
            opacity: .92;
            animation: ${reduceMotion ? "none" : "fadeUp 480ms ease both"};
          }

          /* Bottom bar */
          .bottomBar{
            position: fixed;
            left: 50%;
            bottom: 16px;
            transform: translateX(-50%);
            width: min(980px, 94vw);
          }
          .bottomInner{
            display:flex;
            align-items:center;
            justify-content:space-between;
            gap: 14px;
            padding: 14px 14px;
            border-radius: 999px;
            background: rgba(0,0,0,0.26);
            border: 1px solid rgba(255,255,255,0.16);
            backdrop-filter: blur(14px) saturate(140%);
            -webkit-backdrop-filter: blur(14px) saturate(140%);
            box-shadow: 0 18px 80px rgba(0,0,0,0.34), inset 0 1px 0 rgba(255,255,255,0.14);
            animation: ${reduceMotion ? "none" : "dockIn 900ms cubic-bezier(.16,1,.3,1) both"};
            animation-delay: ${reduceMotion ? "0ms" : "120ms"};
          }
          .bottomLeft{
            display:flex;
            align-items:center;
            gap: 10px;
            min-width: 220px;
          }
          .brandMark{
            width: 40px;
            height: 40px;
            border-radius: 999px;
            display:grid;
            place-items:center;
            background: radial-gradient(circle at 30% 30%, rgba(255,255,255,0.16), rgba(0,0,0,0.18));
            border: 1px solid rgba(255,255,255,0.14);
            box-shadow: 0 10px 30px rgba(0,0,0,0.22);
          }
          .bottomTitle{
            font-weight: 1000;
            letter-spacing: 1.2px;
            font-size: 12px;
            text-transform: uppercase;
            opacity: .9;
          }
          .bottomSub{
            font-weight: 850;
            opacity: .78;
            font-size: 12px;
            margin-top: 2px;
          }
          .barWrap{
            flex: 1;
            min-width: 180px;
            position: relative;
          }
          .barTrack{
            height: 12px;
            border-radius: 999px;
            background: rgba(255,255,255,0.10);
            border: 1px solid rgba(255,255,255,0.12);
            overflow:hidden;
          }
          .barFill{
            height: 100%;
            background: linear-gradient(90deg, rgba(255,214,10,0.95), rgba(255,149,0,0.95), rgba(255,45,85,0.80));
            filter: saturate(120%);
          }
          .barGlow{
            position:absolute;
            inset:-18px -22px;
            background: radial-gradient(circle at 50% 50%, rgba(255,214,10,0.18), rgba(255,149,0,0.14), rgba(255,45,85,0.06), transparent 70%);
            filter: blur(18px);
            opacity: .9;
            pointer-events:none;
            animation: ${reduceMotion ? "none" : "glowFloat 3.6s ease-in-out infinite"};
          }
          .timeBox{
            min-width: 70px;
            height: 40px;
            border-radius: 999px;
            display:grid;
            place-items:center;
            font-size: 18px;
            font-weight: 1000;
            background: rgba(255,255,255,0.10);
            border: 1px solid rgba(255,255,255,0.14);
            box-shadow: inset 0 1px 0 rgba(255,255,255,0.12);
          }

          /* background layers */
          .grain{
            position:absolute;
            inset:0;
            background-image:
              url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='120' height='120' filter='url(%23n)' opacity='.35'/%3E%3C/svg%3E");
            opacity: .10;
            mix-blend-mode: overlay;
            pointer-events:none;
          }
          .orbs{ position:absolute; inset:0; pointer-events:none; overflow:hidden; }
          .orb{ position:absolute; border-radius: 999px; filter: blur(24px); opacity: .75; mix-blend-mode: screen; }
          .o1{
            width: 420px; height: 420px; left: -120px; top: -120px;
            background: radial-gradient(circle at 30% 30%, rgba(255,214,10,0.26), rgba(255,149,0,0.18), transparent 70%);
            animation: ${reduceMotion ? "none" : "orbFloat 8s ease-in-out infinite"};
          }
          .o2{
            width: 360px; height: 360px; right: -120px; top: 40px;
            background: radial-gradient(circle at 30% 30%, rgba(34,211,238,0.18), rgba(167,139,250,0.12), transparent 72%);
            animation: ${reduceMotion ? "none" : "orbFloat 9.5s ease-in-out infinite"};
            animation-delay: ${reduceMotion ? "0s" : "-1.2s"};
          }
          .o3{
            width: 520px; height: 520px; left: 20%; bottom: -220px;
            background: radial-gradient(circle at 30% 30%, rgba(255,45,85,0.14), rgba(255,149,0,0.16), transparent 70%);
            animation: ${reduceMotion ? "none" : "orbFloat 10.5s ease-in-out infinite"};
            animation-delay: ${reduceMotion ? "0s" : "-2.1s"};
          }

          /* animations */
          @keyframes fadeUp{
            from{ opacity:0; transform: translateY(10px); }
            to{ opacity:1; transform: translateY(0); }
          }
          @keyframes heroIn{
            0%{ opacity:0; transform: translateY(12px) scale(0.985); filter: blur(1px); }
            100%{ opacity:1; transform: translateY(0) scale(1); filter: blur(0); }
          }
          @keyframes cardIn{
            0%{ opacity:0; transform: translateY(16px) scale(0.985); }
            100%{ opacity:1; transform: translateY(0) scale(1); }
          }
          @keyframes dockIn{
            0%{ opacity:0; transform: translateY(16px); }
            100%{ opacity:1; transform: translateY(0); }
          }
          @keyframes glowFloat{
            0%,100%{ transform: translateY(0); opacity: .82; }
            50%{ transform: translateY(-6px); opacity: 1; }
          }
          @keyframes shineSweep{
            0%,100%{ transform: translateX(-10px) rotate(12deg); opacity: .60; }
            50%{ transform: translateX(18px) rotate(12deg); opacity: .90; }
          }
          @keyframes selectedBreath{
            0%,100%{ transform: scale(1.01); filter: brightness(1.06); }
            50%{ transform: scale(1.025); filter: brightness(1.14); }
          }
          @keyframes orbFloat{
            0%,100%{ transform: translateY(0) translateX(0); }
            50%{ transform: translateY(18px) translateX(10px); }
          }

          @media (max-width: 980px){
            .glassCard{ min-height: 230px; }
          }
          @media (max-width: 860px){
            .topicGrid{ grid-template-columns: 1fr; }
            .glassCard{ min-height: 190px; }
            .bottomLeft{ min-width: 160px; }
            .timeBox{ min-width: 64px; }
          }
        `}</style>
            </main>
        );
    }

    // =========================================================
    // PHASE: COUNTDOWN
    // =========================================================
    if (lobby.phase === "countdown") {
        const tie = lobby.topic_tie_choices && lobby.topic_tie_choices.length > 1;
        const tieChoices = lobby.topic_tie_choices ?? [];
        const pick = lobby.topic_tie_pick;

        const labelForChoice = (c: number) => {
            if (c === 1) return `① ${aLabel}`;
            if (c === 2) return `② ${bLabel}`;
            if (c === 3) return `🎲 ${rLabel}`;
            return String(c);
        };

        const isWinner = (c: 1 | 2 | 3) => winnerChoice === c;

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
                <div style={{ width: "min(1100px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>THEMA GEWÄHLT</div>

                    <div
                        style={{
                            marginTop: 16,
                            display: "grid",
                            gridTemplateColumns: "repeat(3, minmax(0,1fr))",
                            gap: 14,
                            alignItems: "stretch",
                        }}
                    >
                        <div className={`resultTile ${isWinner(1) ? "win" : "lose"}`}>
                            <div className="resultBadge">①</div>
                            <div className="resultTitle">{aLabel}</div>
                        </div>

                        <div className={`resultTile ${isWinner(2) ? "win" : "lose"}`}>
                            <div className="resultBadge">②</div>
                            <div className="resultTitle">{bLabel}</div>
                        </div>

                        <div className={`resultTile ${isWinner(3) ? "win" : "lose"}`}>
                            <div className="resultBadge">🎲</div>
                            <div className="resultTitle">{rLabel}</div>
                        </div>
                    </div>

                    <div style={{ fontSize: "clamp(28px, 4.2vw, 52px)", fontWeight: 950, marginTop: 18 }}>{selectedTopic}</div>

                    {tie ? (
                        <div style={{ marginTop: 10, opacity: 0.9, fontWeight: 850 }}>
                            Tie zwischen: <span style={{ opacity: 0.98 }}>{tieChoices.map((c) => labelForChoice(c)).join(" · ")}</span>
                            <div style={{ marginTop: 6, opacity: 0.92 }}>
                                Zufällig gewählt: <b>{pick ? labelForChoice(pick) : "…"}</b>
                            </div>
                        </div>
                    ) : (
                        <div style={{ marginTop: 10, opacity: 0.85, fontWeight: 800 }}>Sag gleich was zum Thema.</div>
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

                    {toast ? <div style={{ marginTop: 18, fontWeight: 900, opacity: 0.92 }}>{toast}</div> : null}
                </div>

                <style>{`
          .resultTile{
            border-radius: 28px;
            border: 1px solid rgba(255,255,255,0.14);
            background: rgba(0,0,0,0.18);
            padding: 16px 14px;
            text-align:left;
            backdrop-filter: blur(10px);
            -webkit-backdrop-filter: blur(10px);
            overflow:hidden;
            position:relative;
            transform-origin: center;
          }
          .resultBadge{
            display:inline-flex;
            align-items:center;
            justify-content:center;
            height: 34px;
            padding: 0 12px;
            border-radius: 999px;
            font-weight: 950;
            background: rgba(255,255,255,0.12);
            border: 1px solid rgba(255,255,255,0.14);
          }
          .resultTitle{
            margin-top: 14px;
            font-size: clamp(18px, 2.2vw, 28px);
            font-weight: 950;
            text-shadow: 0 10px 30px rgba(0,0,0,0.22);
          }

          @keyframes winPop {
            0% { transform: scale(1); filter: brightness(1); }
            70% { transform: scale(1.06); filter: brightness(1.18); }
            100% { transform: scale(1.04); filter: brightness(1.12); }
          }
          @keyframes loseSlide {
            0% { transform: scale(1); opacity: 1; }
            100% { transform: translateY(14px) scale(0.92); opacity: 0.12; }
          }

          .resultTile.win{
            background: radial-gradient(circle at 30% 30%, rgba(255,255,255,0.16), rgba(0,0,0,0.18)),
                        linear-gradient(135deg, rgba(52,199,89,0.18), rgba(10,132,255,0.10), rgba(255,214,10,0.12));
            border-color: rgba(255,255,255,0.28);
            box-shadow: 0 18px 70px rgba(0,0,0,0.25);
            animation: winPop .55s ease-out forwards;
          }
          .resultTile.lose{
            animation: loseSlide .55s ease-out forwards;
          }

          @media (max-width: 860px){
            main div[style*="gridTemplateColumns: repeat(3"]{
              grid-template-columns: 1fr !important;
            }
          }
        `}</style>
            </main>
        );
    }

    // =========================================================
    // PHASE: FINISHED
    // =========================================================
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

    // =========================================================
    // PHASE: RUNNING
    // =========================================================
    if (lobby.phase !== "running") {
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
            {isMeHolder ? <div className="holderPulseLayer" aria-hidden /> : null}

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

            <PlayerRing players={players} holderPlayerId={lobby.holder_player_id} mePlayerId={mePlayerId} />

            <div style={{ position: "relative", zIndex: 2, minHeight: "100vh", display: "grid", placeItems: "center", padding: 24 }}>
                <div style={{ width: "min(860px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>RUNNING</div>
                    <div style={{ fontSize: "clamp(28px, 4.2vw, 56px)", fontWeight: 950, marginTop: 12 }}>{selectedTopic}</div>

                    <div style={{ marginTop: 12, opacity: 0.9, fontWeight: 850 }}>
                        Holder: <b>{holderName}</b>
                    </div>

                    <div style={{ marginTop: 18, display: "flex", justifyContent: "center", gap: 12, flexWrap: "wrap" }}>
                        <button className="btn btnSecondary btnXL" onClick={() => goLobby(code)} type="button">
                            Zur Lobby
                        </button>

                        <button
                            className="btn btnPrimary btnXL"
                            onClick={() => void handlePass()}
                            type="button"
                            disabled={!mePlayerId || passBusy || iAmEliminated || !isMeHolder}
                            title={!isMeHolder ? "Du hast die Kartoffel nicht" : iAmEliminated ? "Du bist raus" : "Weitergeben"}
                        >
                            {isMeHolder ? (passBusy ? "…" : "🥔 Weitergeben (Space)") : "⛔ Nicht Holder"}
                        </button>
                    </div>

                    <div style={{ marginTop: 12, opacity: 0.8, fontWeight: 800 }}>
                        {isMeHolder ? "Du hast die Kartoffel. Drück Space oder Button." : "Warte, bis du die Kartoffel bekommst."}
                    </div>
                </div>
            </div>

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