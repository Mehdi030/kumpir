"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

import { PlayerRing } from "@/components/game/PlayerRing";
import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";

type LobbyPhase =
    | "lobby"
    | "topic_vote"
    | "countdown"
    | "running"
    | "finished"
    | string;

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

type PassEvent = {
    fromPlayerId: string;
    toPlayerId: string;
    nonce: number; // force change detection
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

function clamp(n: number, min: number, max: number) {
    return Math.max(min, Math.min(max, n));
}

function msUntil(ts: string | null): number | null {
    if (!ts) return null;
    const ms = Date.parse(ts);
    if (Number.isNaN(ms)) return null;
    return ms - Date.now();
}

function pickNextAlive(players: Player[], holderId: string | null): Player | null {
    if (!holderId) return null;
    if (players.length === 0) return null;

    const alive = players.filter((p) => p.is_alive);
    if (alive.length <= 1) return null;

    const idx = alive.findIndex((p) => p.player_id === holderId);
    if (idx < 0) return alive[0] ?? null;

    for (let step = 1; step <= alive.length; step++) {
        const p = alive[(idx + step) % alive.length];
        if (p?.is_alive) return p;
    }
    return null;
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

    // Motion
    const [reduceMotion, setReduceMotion] = useState(false);

    // “Your turn” overlay (1x per transition)
    const [turnOverlay, setTurnOverlay] = useState(false);
    const lastShownTurnNonceRef = useRef<number>(0);

    // Pass animation event
    const [passEvent, setPassEvent] = useState<PassEvent | null>(null);

    // holder transition tracking
    const prevHolderRef = useRef<string | null>(null);
    const passNonceRef = useRef(0);

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
        return 3;
    }, [lobby]);

    const totalPlayers = players.length;
    const votedPlayers = voteCounts.a + voteCounts.b + voteCounts.r;
    const allVoted = totalPlayers > 0 && votedPlayers >= totalPlayers;

    // Spectator HUD data
    const nextUp = useMemo(
        () => pickNextAlive(players, lobby?.holder_player_id ?? null),
        [players, lobby?.holder_player_id]
    );

    const explodeSecondsLeft = useMemo(() => {
        if (!lobby?.explode_at) return null;
        const ms = msUntil(lobby.explode_at);
        if (ms === null) return null;
        return clamp(Math.ceil(ms / 1000), 0, 999);
    }, [lobby?.explode_at]);

    // -----------------------------
    // RPC wrappers (NO throw)
    // -----------------------------
    const rpcFinalizeTopicVote = useCallback(
        async (lobbyId: string): Promise<{ ok: true } | { ok: false; error: string }> => {
            const { error } = await supabase.rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
            if (error) {
                console.error("rpc_finalize_topic_vote failed:", error);
                showToast(`❌ Finalize: ${error.message}`, 2400);
                return { ok: false, error: error.message };
            }
            return { ok: true };
        },
        [supabase, showToast]
    );

    const rpcAdvanceFromCountdown = useCallback(
        async (lobbyId: string): Promise<{ ok: true } | { ok: false; error: string }> => {
            const { error } = await supabase.rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });
            if (error) {
                console.error("rpc_advance_from_countdown failed:", error);
                showToast(`❌ Advance: ${error.message}`, 2400);
                return { ok: false, error: error.message };
            }
            return { ok: true };
        },
        [supabase, showToast]
    );

    const rpcTickGame = useCallback(
        async (codeUpper: string) => {
            const { error } = await supabase.rpc("rpc_tick_game", { p_code: codeUpper });
            if (error) console.error("rpc_tick_game failed:", error);
        },
        [supabase]
    );

    const rpcPassPotato = useCallback(
        async (codeUpper: string, playerId: string) => {
            const { error } = await supabase.rpc("rpc_pass_potato", {
                p_code: codeUpper,
                p_player_id: playerId,
            });
            return error;
        },
        [supabase]
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

                // BEFORE setLobby: compute holder transition (for overlay + pass anim)
                const prevHolder = prevHolderRef.current;
                const nextHolder = nextLobby.holder_player_id ?? null;

                // Pass animation event: when holder changes (and both exist)
                if (prevHolder && nextHolder && prevHolder !== nextHolder) {
                    passNonceRef.current += 1;
                    setPassEvent({
                        fromPlayerId: prevHolder,
                        toPlayerId: nextHolder,
                        nonce: passNonceRef.current,
                    });
                }

                // "Du bist dran" overlay: only when transition enters me
                if (mePlayerId && nextHolder === mePlayerId && prevHolder !== mePlayerId) {
                    const nonce = Date.now();
                    if (nonce - lastShownTurnNonceRef.current > 700) {
                        lastShownTurnNonceRef.current = nonce;
                        setTurnOverlay(true);
                        window.setTimeout(() => setTurnOverlay(false), 1700);
                    }
                }

                prevHolderRef.current = nextHolder;

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
                    const votesRes = await supabase
                        .from("topic_votes")
                        .select("choice,player_id")
                        .eq("lobby_id", nextLobby.id);

                    if (!alive) return;

                    if (votesRes.error) {
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
                                if (row.choice === 1 || row.choice === 2 || row.choice === 3) {
                                    mine = row.choice as 1 | 2 | 3;
                                }
                            }
                        }
                        setVoteCounts({ a, b, r });
                        setMyVote(mine);
                    }
                } else {
                    setVoteCounts({ a: 0, b: 0, r: 0 });
                    setMyVote(null);
                }

                // ---- Best-effort “advance” calls

                // 1) running: tick due (OPTION A: nur HOLDER tickt)
                if (mePlayerId && nextLobby.phase === "running" && nextLobby.explode_at) {
                    const meAlive = nextPlayers.find((p) => p.player_id === mePlayerId)?.is_alive ?? true;

                    const iAmHolderNow = nextLobby.holder_player_id === mePlayerId;
                    if (iAmHolderNow) {
                        const explodeMs = Date.parse(nextLobby.explode_at);
                        const due = !Number.isNaN(explodeMs) && Date.now() >= explodeMs - 150;

                        if (meAlive && due) {
                            void rpcTickGame(code);
                        }
                    }
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
    }, [code, supabase, mePlayerId, rpcFinalizeTopicVote, rpcAdvanceFromCountdown, rpcTickGame, showToast]);

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
                const { error } = await supabase.rpc("rpc_vote_topic", {
                    p_lobby_id: lobby.id,
                    p_player_id: mePlayerId,
                    p_choice: choice,
                });

                if (error) {
                    console.error("rpc_vote_topic failed:", error);
                    showToast(`❌ ${error.message}`, 2600);
                    return;
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
    // PASS handler (RPC-only)
    // -----------------------------
    const handlePass = useCallback(async () => {
        if (!mePlayerId) return showToast("⚠️ Keine Player-ID", 1800);
        if (!lobby || lobby.phase !== "running") return showToast("⏳ Noch nicht gestartet", 1400);
        if (iAmEliminated) return showToast("💀 Du bist raus", 1400);
        if (!isMeHolder) return;
        if (passBusy) return;

        setPassBusy(true);
        try {
            const err = await rpcPassPotato(code, mePlayerId);
            if (err) {
                showToast(`❌ ${err.message}`, 2400);
                return;
            }
            showToast("✅ Weitergegeben", 900);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2400);
        } finally {
            setPassBusy(false);
        }
    }, [mePlayerId, lobby, iAmEliminated, isMeHolder, passBusy, code, rpcPassPotato, showToast]);

    // Spacebar pass (nur running, nur Holder)
    useEffect(() => {
        const onKeyDown = (ev: KeyboardEvent) => {
            if (ev.code !== "Space") return;
            if (!lobby || lobby.phase !== "running") return;
            if (!isMeHolder) return;
            ev.preventDefault();
            void handlePass();
        };

        window.addEventListener("keydown", onKeyDown, { passive: false });
        return () => window.removeEventListener("keydown", onKeyDown);
    }, [handlePass, lobby, isMeHolder]);

    // -----------------------------
    // UI: fatal / loading
    // -----------------------------
    if (fatalError) {
        return (
            <main style={{ minHeight: "100vh", display: "grid", placeItems: "center", padding: 24 }}>
                <div style={{ width: "min(720px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontWeight: 950, fontSize: 22 }}>⚠️ Spiel konnte nicht geladen werden</div>
                    <div style={{ marginTop: 10, opacity: 0.8 }}>{fatalError}</div>
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
    // PHASE: TOPIC VOTE
    // =========================================================
    if (lobby.phase === "topic_vote") {
        const timeLeft = voteSecondsLeft ?? 15;
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

                        <div className="statusLine">
                            {allVoted ? "✅ Alle haben gewählt – wird ausgewertet…" : "Wählt schnell – bei allen Votes geht’s sofort weiter."}
                        </div>

                        {toast ? <div className="toastInline">{toast}</div> : null}
                    </div>
                </div>

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

                {/* styles unverändert */}
                <style>{`/* ... dein kompletter CSS-Block bleibt hier exakt so wie bei dir ... */`}</style>
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
                {/* ... dein Countdown UI bleibt unverändert ... */}
                {/* (ich lasse den Rest hier bewusst wie bei dir) */}
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
                {/* ... dein Finished UI bleibt unverändert ... */}
            </main>
        );
    }

    // =========================================================
    // PHASE: NOT RUNNING (WARTEN)
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
                {/* ... dein Waiting UI bleibt unverändert ... */}
            </main>
        );
    }

    const runningBg = isMeHolder
        ? "radial-gradient(circle at 50% 35%, rgba(255,120,80,0.55) 0%, rgba(143,15,15,0.96) 72%)"
        : "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.08) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(52,199,89,0.26) 0%, rgba(0,130,60,0.78) 80%)";

    // =========================================================
    // PHASE: RUNNING
    // =========================================================
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
            <PlayerRing
                players={players}
                holderPlayerId={lobby.holder_player_id}
                mePlayerId={mePlayerId}
                passEvent={passEvent}
            />

            {isMeHolder ? <div className="holderPulseLayer" aria-hidden /> : null}

            {turnOverlay ? (
                <div
                    style={{
                        position: "fixed",
                        left: "50%",
                        top: 22,
                        transform: "translateX(-50%)",
                        zIndex: 9999,
                        padding: "12px 16px",
                        borderRadius: 999,
                        background: "rgba(0,0,0,0.62)",
                        border: "1px solid rgba(255,255,255,0.14)",
                        fontWeight: 950,
                        letterSpacing: 0.3,
                        backdropFilter: "blur(10px)",
                        WebkitBackdropFilter: "blur(10px)",
                    }}
                >
                    ✅ Du bist dran
                </div>
            ) : null}

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

            <div style={{ position: "relative", zIndex: 3, minHeight: "100vh", display: "grid", placeItems: "center", padding: 24 }}>
                <div style={{ width: "min(920px, 96vw)", textAlign: "center" }}>
                    {iAmEliminated ? (
                        <div
                            style={{
                                marginBottom: 14,
                                display: "inline-flex",
                                gap: 10,
                                alignItems: "center",
                                padding: "10px 12px",
                                borderRadius: 999,
                                background: "rgba(0,0,0,0.30)",
                                border: "1px solid rgba(255,255,255,0.12)",
                                backdropFilter: "blur(10px)",
                                WebkitBackdropFilter: "blur(10px)",
                                fontWeight: 900,
                            }}
                        >
                            <span style={{ opacity: 0.9 }}>👁️ Spectator</span>
                            <span style={{ opacity: 0.75 }}>•</span>
                            <span style={{ opacity: 0.9 }}>
                Jetzt: <b>{holderName}</b>
              </span>
                            {nextUp ? (
                                <>
                                    <span style={{ opacity: 0.75 }}>•</span>
                                    <span style={{ opacity: 0.9 }}>
                    Next: <b>{nextUp.name}</b>
                  </span>
                                </>
                            ) : null}
                            {typeof explodeSecondsLeft === "number" ? (
                                <>
                                    <span style={{ opacity: 0.75 }}>•</span>
                                    <span style={{ opacity: 0.9 }}>💣 {explodeSecondsLeft}s</span>
                                </>
                            ) : null}
                        </div>
                    ) : null}

                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>RUNNING</div>
                    <div style={{ fontSize: "clamp(28px, 4.2vw, 56px)", fontWeight: 950, marginTop: 12 }}>{selectedTopic}</div>

                    <div style={{ marginTop: 12, opacity: 0.9, fontWeight: 850 }}>
                        Holder: <b>{holderName}</b>
                    </div>

                    {isMeHolder && !iAmEliminated ? (
                        <div style={{ marginTop: 18, display: "flex", justifyContent: "center", gap: 12, flexWrap: "wrap" }}>
                            <button
                                className="btn btnPrimary btnXL"
                                onClick={() => void handlePass()}
                                type="button"
                                disabled={!mePlayerId || passBusy}
                                title="Weitergeben"
                            >
                                {passBusy ? "…" : "🥔 Weitergeben (Space)"}
                            </button>
                        </div>
                    ) : null}

                    <div style={{ marginTop: 12, opacity: 0.8, fontWeight: 800 }}>
                        {iAmEliminated ? "Du schaust zu." : isMeHolder ? "Du hast die Kartoffel. Drück Space oder Button." : "Warte, bis du die Kartoffel bekommst."}
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
          z-index: 1;
        }
      `}</style>
        </main>
    );
}