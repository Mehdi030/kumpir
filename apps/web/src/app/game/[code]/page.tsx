"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

import { PlayerRing } from "@/components/game/PlayerRing";
import { VoiceInput } from "@/components/game/VoiceInput";
import { SongRound } from "@/components/game/SongRound";
import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyRealtime } from "@/hooks/useLobbyRealtime";
import { useHeartbeat } from "@/hooks/useHeartbeat";
import { usePassAttempt } from "@/hooks/usePassAttempt";
import { useBotEngine } from "@/hooks/useBotEngine";
import { useNewAchievements } from "@/hooks/useNewAchievements";
import { useAuth } from "@/components/AuthProvider";
import { AchievementToastPortal } from "@/components/AchievementToastPortal";
import { BackdropFx } from "@/components/game/BackdropFx";
import { notify } from "@/lib/notifications";
import { GAME_MODES, type GameMode } from "@/lib/gameConfig";
import { MUSIC_PLAYLISTS } from "@/lib/musicGenres";
import { useToastStack } from "@/hooks/useToastStack";
import { ToastStack } from "@/components/ToastStack";
import { Spinner } from "@/components/Spinner";
import { Confetti } from "@/components/Confetti";
import { ConnectionPill } from "@/components/ConnectionPill";
import { AudioControl } from "@/components/AudioControl";
import { playFx } from "@/lib/gameFx";

// Ein pass_attempt ohne Timeout konnte für immer "pending" hängen bleiben,
// sobald bei wenigen lebenden Spielern (v_alive <= 2) Einstimmigkeit
// gefordert war und ein einzelner Spieler nicht (oder gegensätzlich)
// abstimmte -- siehe BALANCE_REPORT.md, Fund #2. Jeder verbundene Client
// löst nach dieser Frist rpc_resolve_stale_attempt aus (idempotent).
const STALE_ATTEMPT_MS = 8000;

type LobbyPhase = "waiting" | "lobby" | "topic_vote" | "countdown" | "running" | "finished" | string;

type LobbyState = {
    id: string;
    code: string;

    phase: LobbyPhase;
    host_player_id: string | null;
    holder_player_id: string | null;

    explode_at: string | null;

    run_started_at: string | null;
    last_activity_at: string | null;

    round_number: number | null;
    last_loser_player_id: string | null;

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

    // Topic-Mechanik B: Antwort-Validierung
    current_attempt_id: string | null;
    used_answers: string[];

    // Modus-Anzeige
    game_mode: string | null;
    pass_direction: number | null;

    // Song-Raten (Musik-Modus): aktueller, versteckter Song für den Halter
    current_song_id: string | null;

    // Antwort-Modus: "text" (Standard) oder "voice" (Sprache primär)
    answer_mode: string | null;
};

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
    ready?: boolean;
    is_bot?: boolean;
    status?: string;

    // optional stats (safe)
    last_pass_at?: string | null;
    pass_count?: number;
    clutch_pass_count?: number;
    fastest_pass_ms?: number | null;
    total_hold_ms?: number;
    survival_streak?: number;
    last_seen_at?: string | null;
};

type VoteCounts = { a: number; b: number; r: number };

type PassEvent = {
    fromPlayerId: string;
    toPlayerId: string;
    nonce: number;
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

function fmtMs(ms?: number | null) {
    if (ms == null) return "—";
    if (ms < 1000) return `${Math.round(ms)} ms`;
    return `${(ms / 1000).toFixed(2)} s`;
}

function fmtHold(ms?: number) {
    if (!ms) return "—";
    const s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    const r = s % 60;
    return `${m}m ${r}s`;
}

function pickNextAlive(players: Player[], holderId: string | null): Player | null {
    if (!holderId) return null;
    const alive = players.filter((p) => p.is_alive);
    if (alive.length <= 1) return null;

    const idx = alive.findIndex((p) => p.player_id === holderId);
    if (idx < 0) return alive[0] ?? null;
    return alive[(idx + 1) % alive.length] ?? null;
}

export default function GamePage() {
    const supabase = getSupabaseClient();
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId } = usePlayerIdentity();
    const { user } = useAuth();

    const [lobby, setLobby] = useState<LobbyState | null>(null);
    const [players, setPlayers] = useState<Player[]>([]);
    const [fatalError, setFatalError] = useState<string>("");

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
    const { toasts, pushToast } = useToastStack({ maxVisible: 3 });
    const [passBusy, setPassBusy] = useState(false);

    // Topic-Mechanik B: Antwort-Eingabe + Validierung
    const [answerDraft, setAnswerDraft] = useState("");
    const [voteBusyAttempt, setVoteBusyAttempt] = useState(false);

    // Motion
    const [reduceMotion, setReduceMotion] = useState(false);

    // “Your turn” overlay
    const [turnOverlay, setTurnOverlay] = useState(false);
    const lastShownTurnNonceRef = useRef<number>(0);

    // Pass animation event
    const [passEvent, setPassEvent] = useState<PassEvent | null>(null);

    // Elimination animation: set when a player just transitions alive→dead
    const [explodedPlayerId, setExplodedPlayerId] = useState<string | null>(null);
    const [selfShake, setSelfShake] = useState(false);

    // HUD swap animation trigger
    const [hudPulseNonce, setHudPulseNonce] = useState(0);

    const inFlightRef = useRef(false);
    const prevHolderRef = useRef<string | null>(null);
    const passNonceRef = useRef(0);
    const prevAliveRef = useRef<Set<string>>(new Set());
    const prevPhaseRef = useRef<LobbyPhase | null>(null);
    const lastTickSecondRef = useRef<number>(-1);

    // Rematch / reset busy
    const [endActionBusy, setEndActionBusy] = useState<null | "rematch" | "reset">(null);

    // rematch_wait: Bereit-Toggle + Auto-Start sobald alle bereit sind
    const [readyBusy, setReadyBusy] = useState(false);
    const startRematchInFlightRef = useRef(false);

    // post-round feedback
    const lastLoserRef = useRef<string | null>(null);

    // Finished screen UI
    const [showFullRanking, setShowFullRanking] = useState(false);

    useEffect(() => {
        if (typeof window === "undefined") return;
        const mq = window.matchMedia?.("(prefers-reduced-motion: reduce)");
        const apply = () => setReduceMotion(!!mq?.matches);
        apply();
        mq?.addEventListener?.("change", apply);
        return () => mq?.removeEventListener?.("change", apply);
    }, []);

    const showToast = useCallback(
        (msg: string, ms = 1600) => {
            pushToast(msg, ms);
        },
        [pushToast]
    );

    const meRow = useMemo(() => {
        if (!mePlayerId) return null;
        return players.find((p) => p.player_id === mePlayerId) ?? null;
    }, [players, mePlayerId]);

    const iAmEliminated = !!meRow && !meRow.is_alive;

    const isMeHolder = useMemo(() => {
        if (!mePlayerId || !lobby?.holder_player_id) return false;
        return lobby.holder_player_id === mePlayerId;
    }, [lobby?.holder_player_id, mePlayerId]);

    const holderRow = useMemo(() => {
        if (!lobby?.holder_player_id) return null;
        return players.find((p) => p.player_id === lobby.holder_player_id) ?? null;
    }, [players, lobby?.holder_player_id]);

    const holderName = useMemo(() => holderRow?.name ?? "…", [holderRow]);

    const selectedTopic = useMemo(() => {
        if (lobby?.phase === "topic_vote") return lobby?.topic_a ?? "…";
        return lobby?.topic_selected ?? lobby?.topic_a ?? "…";
    }, [lobby?.phase, lobby?.topic_selected, lobby?.topic_a]);

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

    const nextUp = useMemo(() => pickNextAlive(players, lobby?.holder_player_id ?? null), [players, lobby?.holder_player_id]);

    // Verbindung wirkt verloren: last_seen_at (Heartbeat alle ~8s) ist älter
    // als 20s. Reines UI-Signal, ändert keine Server-Logik/Elimination.
    const disconnectedIds = useMemo(() => {
        const STALE_MS = 20000;
        const now = Date.now();
        const set = new Set<string>();
        for (const p of players) {
            if (!p.is_alive || !p.last_seen_at) continue;
            const seen = Date.parse(p.last_seen_at);
            if (!Number.isNaN(seen) && now - seen > STALE_MS) set.add(p.player_id);
        }
        return set;
    }, [players]);

    // Winner / Ranking
    const winnerPlayer = useMemo(() => {
        if (!lobby?.holder_player_id) return null;
        return players.find((p) => p.player_id === lobby.holder_player_id) ?? null;
    }, [players, lobby?.holder_player_id]);

    const ranking = useMemo(() => {
        const rows = players.map((p) => {
            const pass = p.pass_count ?? 0;
            const clutch = p.clutch_pass_count ?? 0;
            const streak = p.survival_streak ?? 0;
            const fastest = p.fastest_pass_ms ?? null;

            const fastestBonus = fastest == null ? 0 : Math.max(0, Math.min(12, Math.round((2200 - fastest) / 200)));
            const score = pass * 10 + clutch * 18 + streak * 6 + fastestBonus;

            return {
                ...p,
                score,
                pass,
                clutch,
                streak,
                fastest,
                holdMs: p.total_hold_ms ?? 0,
            };
        });

        rows.sort((a, b) => b.score - a.score);
        return rows;
    }, [players]);

    const top5 = useMemo(() => ranking.slice(0, 5), [ranking]);

    // Jeder Spieler bekommt genau eine Auszeichnung -- nicht nur die zwei
    // Gesamtsieger-Kategorien von früher. Reihenfolge = Priorität: die
    // erste Kategorie, in der ein Spieler noch nicht durch einen anderen
    // "verbraucht" wurde, gewinnt er. Wer in keiner Kategorie vorne landet
    // (bei vielen Spielern normal), bekommt die Teilnahme-Auszeichnung mit
    // seiner eigenen Bestleistung als Text -- niemand geht leer aus.
    const playerAwards = useMemo(() => {
        const awarded = new Map<string, { icon: string; label: string; value: string; desc: string }>();

        if (winnerPlayer) {
            awarded.set(winnerPlayer.player_id, {
                icon: "🏆",
                label: "Sieger",
                value: winnerPlayer.name,
                desc: "Hat als letzte(r) überlebt",
            });
        }

        type Row = (typeof ranking)[number];
        const categories: {
            icon: string;
            label: string;
            desc: string;
            get: (r: Row) => number | null | undefined;
            fmt: (r: Row) => string;
            higherIsBetter: boolean;
        }[] = [
            { icon: "⚡", label: "Fastest Pass", desc: "Schnellste Reaktion im Match", get: (r) => r.fastest, fmt: (r) => fmtMs(r.fastest), higherIsBetter: false },
            { icon: "🧱", label: "Longest Hold", desc: "Längste Haltezeit insgesamt", get: (r) => r.holdMs, fmt: (r) => fmtHold(r.holdMs), higherIsBetter: true },
            { icon: "🔥", label: "Meiste Pässe", desc: "Am häufigsten weitergegeben", get: (r) => r.pass, fmt: (r) => `${r.pass}x`, higherIsBetter: true },
            { icon: "🎯", label: "Clutch-King", desc: "Meiste Last-Second-Pässe", get: (r) => r.clutch, fmt: (r) => `${r.clutch}x`, higherIsBetter: true },
            { icon: "🛡️", label: "Beste Serie", desc: "Längste Überlebens-Serie am Stück", get: (r) => r.streak, fmt: (r) => `${r.streak} Runden`, higherIsBetter: true },
        ];

        for (const cat of categories) {
            const candidates = ranking
                .filter((r) => !awarded.has(r.player_id))
                .filter((r) => {
                    const v = cat.get(r);
                    return v != null && v > 0;
                })
                .sort((a, b) => {
                    const av = cat.get(a) ?? 0;
                    const bv = cat.get(b) ?? 0;
                    return cat.higherIsBetter ? bv - av : av - bv;
                });

            const winner = candidates[0];
            if (winner) {
                awarded.set(winner.player_id, {
                    icon: cat.icon,
                    label: cat.label,
                    value: cat.fmt(winner),
                    desc: cat.desc,
                });
            }
        }

        // Teilnahme-Auszeichnung für alle, die sonst leer ausgehen würden.
        for (const r of ranking) {
            if (awarded.has(r.player_id)) continue;
            awarded.set(r.player_id, {
                icon: "🎉",
                label: "Mit vollem Einsatz dabei",
                value: `${r.pass} ${r.pass === 1 ? "Pass" : "Pässe"}`,
                desc: "Hat die Kartoffel nie fallen lassen",
            });
        }

        return awarded;
    }, [ranking, winnerPlayer]);

    const myRankRow = useMemo(() => {
        if (!mePlayerId) return null;
        const idx = ranking.findIndex((r) => r.player_id === mePlayerId);
        if (idx < 0) return null;
        return { row: ranking[idx], rank: idx + 1 };
    }, [ranking, mePlayerId]);

    // -----------------------------
    // RPC wrappers
    // -----------------------------
    const rpcFinalizeTopicVote = useCallback(
        async (lobbyId: string) => {
            const { error } = await supabase.rpc("rpc_finalize_topic_vote", { p_lobby_id: lobbyId });
            if (error) {
                showToast(`❌ Finalize: ${error.message}`, 2400);
                return { ok: false as const, error: error.message };
            }
            return { ok: true as const };
        },
        [supabase, showToast]
    );

    const rpcAdvanceFromCountdown = useCallback(
        async (lobbyId: string) => {
            const { error } = await supabase.rpc("rpc_advance_from_countdown", { p_lobby_id: lobbyId });
            if (error) {
                showToast(`❌ Advance: ${error.message}`, 2400);
                return { ok: false as const, error: error.message };
            }
            return { ok: true as const };
        },
        [supabase, showToast]
    );

    const rpcTickGame = useCallback(
        async (codeUpper: string) => {
            await supabase.rpc("rpc_tick_game", { p_code: codeUpper });
        },
        [supabase]
    );

    // Note: direct rpc_pass_potato is no longer called from the client — the
    // server-side _finalize_attempt_accept triggers it once the answer has been
    // validated by the other players (Topic-Mechanik B).

    // Topic-Mechanik B: Halter sagt seine Antwort und startet einen Validierungs-Versuch.
    const rpcAttemptPass = useCallback(
        async (codeUpper: string, playerId: string, answer: string) => {
            const { error } = await supabase.rpc("rpc_attempt_pass", {
                p_code: codeUpper,
                p_player_id: playerId,
                p_answer: answer,
            });
            return error;
        },
        [supabase]
    );

    // Topic-Mechanik B: Mitspieler stimmt ab, ob die Antwort gilt.
    const rpcVoteAnswer = useCallback(
        async (attemptId: string, voterId: string, accept: boolean) => {
            const { error } = await supabase.rpc("rpc_vote_answer", {
                p_attempt_id: attemptId,
                p_voter_id: voterId,
                p_accept: accept,
            });
            return error;
        },
        [supabase]
    );

    // -----------------------------
    // Realtime status — must be declared before the poll loop because the
    // polling cadence depends on it (slow when realtime is "live").
    // -----------------------------
    const reloadFromRealtime = useCallback(() => {
        inFlightRef.current = false;
    }, []);
    const realtimeStatus = useLobbyRealtime(lobby?.id ?? null, reloadFromRealtime);

    // Heartbeat: hält players.last_seen_at während des laufenden Spiels aktuell
    // (auf der Lobby-Seite lief das schon, hier bisher nicht -> ohne das würde
    // last_seen_at beim Rundenstart einfrieren und jeder Spieler sähe sofort
    // als "getrennt" aus). Cleanup bleibt aus (rpc_cleanup_lobby fasst
    // 'running' ohnehin nicht an) -- reine Sichtbarkeit hier.
    useHeartbeat({ lobbyId: lobby?.id ?? null, playerId: mePlayerId, doCleanup: false });

    // -----------------------------
    // Topic-Mechanik B: aktueller Pass-Versuch + Vote-Status
    // -----------------------------
    const passAttempt = usePassAttempt(
        lobby?.id ?? null,
        lobby?.current_attempt_id ?? null,
        mePlayerId
    );

    // Watchdog: löst einen hängenden Pass-Versuch nach STALE_ATTEMPT_MS auf
    // (Mehrheit der bis dahin abgegebenen Stimmen, bei 0:0 im Zweifel für
    // den Halter). Läuft auf jedem verbundenen Client -- die RPC ist
    // idempotent, mehrfache Aufrufe sind harmlos.
    useEffect(() => {
        const attempt = passAttempt.attempt;
        if (!attempt || attempt.status !== "pending") return;

        const createdMs = Date.parse(attempt.created_at);
        if (Number.isNaN(createdMs)) return;

        const delay = Math.max(0, createdMs + STALE_ATTEMPT_MS - Date.now());
        const t = window.setTimeout(() => {
            void supabase.rpc("rpc_resolve_stale_attempt", { p_attempt_id: attempt.id });
        }, delay);

        return () => window.clearTimeout(t);
    }, [passAttempt.attempt, supabase]);

    // -----------------------------
    // Achievement-Toast — beobachtet neue Unlocks beim Spielende
    // -----------------------------
    const achievementTrigger = lobby?.phase === "finished" ? `${lobby?.id}:${lobby?.round_number ?? 0}` : null;
    const { newOnes: newAchievements, dismiss: dismissAchievement } = useNewAchievements(
        user?.id ?? null,
        achievementTrigger
    );

    // -----------------------------
    // Bot-Engine — läuft NUR im Host-Browser, steuert alle is_bot Spieler
    // -----------------------------
    const isHost = !!mePlayerId && lobby?.host_player_id === mePlayerId;
    useBotEngine(
        isHost,
        lobby
            ? {
                  id: lobby.id,
                  code: lobby.code,
                  phase: lobby.phase,
                  host_player_id: lobby.host_player_id,
                  holder_player_id: lobby.holder_player_id,
                  topic_selected: lobby.topic_selected,
                  topic_a: lobby.topic_a,
                  topic_b: lobby.topic_b,
                  current_attempt_id: lobby.current_attempt_id,
                  used_answers: lobby.used_answers ?? [],
                  round_number: lobby.round_number,
              }
            : null,
        players,
        mePlayerId,
        passAttempt.attempt
    );

    // -----------------------------
    // Poll loop (fallback when realtime is offline)
    // -----------------------------
    useEffect(() => {
        let alive = true;

        const load = async () => {
            if (inFlightRef.current) return;
            inFlightRef.current = true;

            try {
                // select("*") statt fester Spaltenliste: macht den Code robust
                // gegen fehlende Spalten (Migration 001 nicht ausgeführt →
                // current_attempt_id / used_answers existieren noch nicht in DB).
                // Werden später per Optional-Access behandelt.
                const lobbyRes = await supabase
                    .from("lobbies")
                    .select("*")
                    .eq("code", code)
                    .single();

                if (!alive) return;

                if (lobbyRes.error || !lobbyRes.data) {
                    setFatalError(lobbyRes.error?.message ?? "Lobby konnte nicht geladen werden.");
                    return;
                }

                // Supabase-js can't infer the shape from a runtime-joined select string,
                // so we cast to a plain record for safe field access.
                const raw = lobbyRes.data as unknown as Record<string, unknown>;

                const nextLobby: LobbyState = {
                    id: String(raw.id ?? ""),
                    code: String(raw.code ?? code),
                    phase: (raw.phase as LobbyPhase) ?? "waiting",
                    host_player_id: (raw.host_player_id as string | null) ?? null,
                    holder_player_id: (raw.holder_player_id as string | null) ?? null,

                    explode_at: (raw.explode_at as string | null) ?? null,

                    last_activity_at: (raw.last_activity_at as string | null) ?? null,
                    run_started_at: (raw.run_started_at as string | null) ?? null,

                    round_number: (raw.round_number as number | null) ?? null,
                    last_loser_player_id: (raw.last_loser_player_id as string | null) ?? null,

                    topic_a: (raw.topic_a as string | null) ?? null,
                    topic_b: (raw.topic_b as string | null) ?? null,
                    topic_selected: (raw.topic_selected as string | null) ?? null,
                    topic_vote_ends_at: (raw.topic_vote_ends_at as string | null) ?? null,

                    countdown_started_at: (raw.countdown_started_at as string | null) ?? null,
                    countdown_ends_at: (raw.countdown_ends_at as string | null) ?? null,

                    topic_tie_choices: (raw.topic_tie_choices as number[] | null) ?? null,
                    topic_tie_pick: (raw.topic_tie_pick as number | null) ?? null,

                    current_attempt_id: (raw.current_attempt_id as string | null) ?? null,
                    used_answers: (raw.used_answers as string[] | null) ?? [],

                    game_mode: (raw.game_mode as string | null) ?? "original",
                    pass_direction: (raw.pass_direction as number | null) ?? 1,

                    current_song_id: (raw.current_song_id as string | null) ?? null,

                    answer_mode: (raw.answer_mode as string | null) ?? "text",
                };

                // Post-round loser toast (once)
                if (nextLobby.last_loser_player_id && nextLobby.last_loser_player_id !== lastLoserRef.current) {
                    lastLoserRef.current = nextLobby.last_loser_player_id;
                    const loserName = players.find((p) => p.player_id === nextLobby.last_loser_player_id)?.name ?? "Jemand";
                    showToast(`💥 ${loserName} ist raus`, 1500);
                }

                // Holder transition (passEvent) + HUD swap animation
                const prevHolder = prevHolderRef.current;
                const nextHolder = nextLobby.holder_player_id ?? null;

                if (prevHolder && nextHolder && prevHolder !== nextHolder) {
                    passNonceRef.current += 1;
                    setPassEvent({
                        fromPlayerId: prevHolder,
                        toPlayerId: nextHolder,
                        nonce: passNonceRef.current,
                    });
                    setHudPulseNonce(passNonceRef.current);
                }

                // “Your turn” overlay + Browser-Notification wenn Tab im Hintergrund
                if (mePlayerId && nextHolder === mePlayerId && prevHolder !== mePlayerId) {
                    const nonce = Date.now();
                    if (nonce - lastShownTurnNonceRef.current > 700) {
                        lastShownTurnNonceRef.current = nonce;
                        setTurnOverlay(true);
                        window.setTimeout(() => setTurnOverlay(false), 1700);

                        notify(
                            "🥔 Du bist dran!",
                            `Antworten zu „${nextLobby.topic_selected ?? nextLobby.topic_a ?? "der Kategorie"}".`,
                            { tag: `turn:${nextLobby.id}` }
                        );
                    }
                }

                prevHolderRef.current = nextHolder;
                setLobby(nextLobby);

                // IMPORTANT: finished => include status "left" too, so a player who
                // disconnected mid-match still shows their final stats. "kicked" stays
                // excluded even when finished -- the host removed them, so they never
                // really played this match (this also covers a player kicked before
                // the match even started, who'd otherwise show up with 0 passes).
                const playersQuery = supabase
                    .from("players")
                    .select(
                        [
                            "player_id",
                            "name",
                            "is_alive",
                            "status",
                            "seat_index",
                            "ready",
                            "is_bot",
                            "last_pass_at",
                            "pass_count",
                            "clutch_pass_count",
                            "fastest_pass_ms",
                            "total_hold_ms",
                            "survival_streak",
                            "last_seen_at",
                        ].join(",")
                    )
                    .eq("lobby_id", nextLobby.id)
                    .order("seat_index", { ascending: true });

                const playersRes =
                    nextLobby.phase === "finished"
                        ? await playersQuery.in("status", ["active", "left"])
                        : await playersQuery.eq("status", "active");

                if (!alive) return;

                if (playersRes.error || !playersRes.data) {
                    setFatalError(playersRes.error?.message ?? "Spieler konnten nicht geladen werden.");
                    return;
                }

                const nextPlayers = playersRes.data as unknown as Player[];
                setPlayers(nextPlayers);
                setFatalError("");

                // Votes
                if (nextLobby.phase === "topic_vote") {
                    const votesRes = await supabase.from("topic_votes").select("choice,player_id").eq("lobby_id", nextLobby.id);
                    if (!alive) return;

                    if (votesRes.error) {
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

                        // PERMA highlight: never overwrite to null during topic_vote
                        setMyVote((prev) => mine ?? prev);
                    }
                } else {
                    setVoteCounts({ a: 0, b: 0, r: 0 });
                    setMyVote(null);
                }

                // Best-effort phase automations
                if (mePlayerId && nextLobby.phase === "running" && nextLobby.explode_at) {
                    // Every CONNECTED client checks the timer -- alive or not, not just
                    // the current holder. rpc_tick_game only ever acts once explode_at
                    // has actually passed (row-locked, idempotent), so redundant calls
                    // are harmless. Gating this on "only the holder's own browser" left
                    // the round permanently stuck whenever the holder was a bot (no
                    // client of its own) or had disconnected -- nobody was left to ever
                    // call it (BALANCE_REPORT.md, Fund #1). Gating it on "only ALIVE
                    // clients" had the same failure mode one step later: once the last
                    // connected human got eliminated, their now-spectating browser
                    // stopped ticking too and the match froze forever with bots still
                    // alive. An eliminated player is still a connected client, so they
                    // keep ticking exactly like any spectator would.
                    const explodeMs = Date.parse(nextLobby.explode_at);
                    const due = !Number.isNaN(explodeMs) && Date.now() >= explodeMs - 150;
                    if (due) void rpcTickGame(code);
                }

                // topic_vote finalize
                if (nextLobby.phase === "topic_vote" && nextLobby.topic_vote_ends_at) {
                    // Springt einmalig auf 5s runter, sobald alle (menschlichen)
                    // Spieler gewählt haben -- Bots zählen nicht mit, ihre Wahl
                    // ist zufällig (useBotEngine.ts). Idempotent/no-op sobald die
                    // Restzeit schon <= 5s ist, siehe Migration 028.
                    void supabase.rpc("rpc_maybe_shorten_topic_vote", { p_lobby_id: nextLobby.id });

                    const dueMs = msUntil(nextLobby.topic_vote_ends_at);
                    if (dueMs !== null && dueMs <= 0 && !finalizeInFlightRef.current) {
                        finalizeInFlightRef.current = true;
                        void rpcFinalizeTopicVote(nextLobby.id).finally(() => (finalizeInFlightRef.current = false));
                    }
                }

                // countdown advance
                if (nextLobby.phase === "countdown" && nextLobby.countdown_ends_at) {
                    const dueMs = msUntil(nextLobby.countdown_ends_at);
                    if (dueMs !== null && dueMs <= 0 && !advanceInFlightRef.current) {
                        advanceInFlightRef.current = true;
                        void rpcAdvanceFromCountdown(nextLobby.id).finally(() => (advanceInFlightRef.current = false));
                    }
                }
            } finally {
                inFlightRef.current = false;
            }
        };

        void load();
        // When realtime is "live": slow polling (4s safety net).
        // When offline/connecting: tight polling (650ms).
        const effectiveMs = realtimeStatus === "live" ? 4000 : 650;
        const t = window.setInterval(() => void load(), effectiveMs);

        return () => {
            alive = false;
            window.clearInterval(t);
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [code, supabase, mePlayerId, rpcFinalizeTopicVote, rpcAdvanceFromCountdown, rpcTickGame, showToast, realtimeStatus]);

    // Early finalize when all voted
    useEffect(() => {
        if (!lobby) return;
        if (lobby.phase !== "topic_vote") return;
        if (!allVoted) return;
        if (finalizeInFlightRef.current) return;

        finalizeInFlightRef.current = true;
        void rpcFinalizeTopicVote(lobby.id).finally(() => (finalizeInFlightRef.current = false));
    }, [allVoted, lobby, rpcFinalizeTopicVote]);

    // Fast, dedicated clock for time-based phase transitions (topic_vote ->
    // countdown, countdown -> running, explode). These fire the instant a
    // stored timestamp is reached, not on a DB row change -- Postgres never
    // emits a realtime event just because the wall clock passed a value, so
    // the main poll loop above (which slows to a 4s safety net once realtime
    // is "live") isn't enough on its own: it left every player waiting up to
    // ~4s after a countdown/vote timer visually hit zero before the phase
    // actually advanced, and the host (whose own state settled first) felt
    // ahead of everyone else. This runs every 250ms against already-fetched
    // `lobby` state (no extra fetch) and reuses the same in-flight guards, so
    // it's just a tighter clock on top of logic that already existed.
    useEffect(() => {
        if (!lobby) return;
        const t = window.setInterval(() => {
            if (lobby.phase === "topic_vote" && lobby.topic_vote_ends_at) {
                const dueMs = msUntil(lobby.topic_vote_ends_at);
                if (dueMs !== null && dueMs <= 0 && !finalizeInFlightRef.current) {
                    finalizeInFlightRef.current = true;
                    void rpcFinalizeTopicVote(lobby.id).finally(() => (finalizeInFlightRef.current = false));
                }
            } else if (lobby.phase === "countdown" && lobby.countdown_ends_at) {
                const dueMs = msUntil(lobby.countdown_ends_at);
                if (dueMs !== null && dueMs <= 0 && !advanceInFlightRef.current) {
                    advanceInFlightRef.current = true;
                    void rpcAdvanceFromCountdown(lobby.id).finally(() => (advanceInFlightRef.current = false));
                }
            } else if (lobby.phase === "running" && lobby.explode_at) {
                const explodeMs = Date.parse(lobby.explode_at);
                if (!Number.isNaN(explodeMs) && Date.now() >= explodeMs - 150) {
                    void rpcTickGame(code);
                }
            }
        }, 250);
        return () => window.clearInterval(t);
    }, [lobby, code, rpcFinalizeTopicVote, rpcAdvanceFromCountdown, rpcTickGame]);

    // (realtimeStatus + reloadFromRealtime above, before the poll loop)

    // ---------- FX: phase transitions ----------
    useEffect(() => {
        const next = lobby?.phase ?? null;
        const prev = prevPhaseRef.current;
        if (next !== prev) {
            if (next === "countdown") playFx("voteWin");
            else if (next === "finished") playFx("victory");
            prevPhaseRef.current = next;
        }
    }, [lobby?.phase]);

    // ---------- FX: countdown tick per second ----------
    useEffect(() => {
        if (lobby?.phase !== "countdown") {
            lastTickSecondRef.current = -1;
            return;
        }
        if (countdownSecondsLeft == null) return;
        if (countdownSecondsLeft !== lastTickSecondRef.current && countdownSecondsLeft > 0) {
            lastTickSecondRef.current = countdownSecondsLeft;
            playFx("tick");
        }
    }, [lobby?.phase, countdownSecondsLeft]);

    // ---------- FX + Animation: elimination detection ----------
    useEffect(() => {
        const prevAlive = prevAliveRef.current;
        const currentAlive = new Set<string>();
        for (const p of players) {
            if (p.is_alive) currentAlive.add(p.player_id);
        }

        if (prevAlive.size > 0) {
            for (const id of prevAlive) {
                if (!currentAlive.has(id)) {
                    setExplodedPlayerId(id);
                    const isMe = !!mePlayerId && id === mePlayerId;
                    playFx(isMe ? "selfExplode" : "explode");
                    if (isMe) {
                        setSelfShake(true);
                        window.setTimeout(() => setSelfShake(false), 700);
                    }
                    window.setTimeout(() => setExplodedPlayerId((cur) => (cur === id ? null : cur)), 900);
                    break;
                }
            }
        }
        prevAliveRef.current = currentAlive;
    }, [players, mePlayerId]);

    // ---------- FX: pass sound when holder changes (only during running) ----------
    useEffect(() => {
        if (passEvent && lobby?.phase === "running") playFx("pass");
    }, [passEvent, lobby?.phase]);

    // ---------- Teleport-Modus: sichtbares Signal statt Sync-Bug-Optik ----------
    // Im Teleport-Modus springt die Kartoffel serverseitig bei JEDEM Pass zu
    // einem zufälligen Spieler (rpc_pass_potato) -- ohne Hinweis sah das wie
    // ein Realtime-Bug aus. Ein Toast pro Pass macht den Sprung als Feature
    // erkennbar.
    useEffect(() => {
        if (!passEvent) return;
        if (lobby?.phase !== "running") return;
        if (lobby?.game_mode !== "teleport") return;
        showToast("🌀 Teleport!", 1100);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [passEvent]);

    // Synced timers
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
                setVoteSecondsLeft(ms === null ? null : clamp(Math.ceil(ms / 1000), 0, 99));
            } else setVoteSecondsLeft(null);

            if (lobby.phase === "countdown") {
                const ms = msUntil(lobby.countdown_ends_at);
                setCountdownSecondsLeft(ms === null ? null : clamp(Math.ceil(ms / 1000), 0, 10));
            } else setCountdownSecondsLeft(null);

            raf = window.requestAnimationFrame(step);
        };

        raf = window.requestAnimationFrame(step);
        return () => {
            if (raf) window.cancelAnimationFrame(raf);
        };
    }, [lobby]);

    // Vote action (optimistic local state so highlight is instant)
    const vote = useCallback(
        async (choice: 1 | 2 | 3) => {
            if (!mePlayerId) return showToast("⚠️ Keine Player-ID", 1800);
            if (!lobby) return;
            if (lobby.phase !== "topic_vote") return;
            if (voteBusy) return;

            const prevVote = myVote;
            setMyVote(choice);
            setVoteBusy(true);
            playFx("vote");

            try {
                const { error } = await supabase.rpc("rpc_vote_topic", {
                    p_lobby_id: lobby.id,
                    p_player_id: mePlayerId,
                    p_choice: choice,
                });

                if (error) {
                    setMyVote(prevVote);
                    showToast(`❌ ${error.message}`, 2600);
                    return;
                }
            } catch (e: unknown) {
                setMyVote(prevVote);
                showToast(`❌ ${getErrorMessage(e)}`, 2600);
            } finally {
                setVoteBusy(false);
            }
        },
        [mePlayerId, lobby, voteBusy, myVote, supabase, showToast]
    );

    // Topic-Mechanik B: Halter sagt seine Antwort → triggert Validierungs-Voting.
    const handleAttemptPass = useCallback(async () => {
        if (!mePlayerId) return showToast("⚠️ Keine Player-ID", 1800);
        if (!lobby || lobby.phase !== "running") return showToast("⏳ Noch nicht gestartet", 1400);
        if (iAmEliminated) return showToast("💀 Du bist raus", 1400);
        if (!isMeHolder) return;
        if (passBusy) return;

        const clean = answerDraft.trim();
        if (!clean) return showToast("✍️ Antwort eingeben", 1400);
        if (clean.length > 60) return showToast("Antwort zu lang (max 60)", 1800);

        const used = (lobby.used_answers ?? []).map((a) => a.toLowerCase());
        if (used.includes(clean.toLowerCase())) {
            return showToast("⚠️ Schon gesagt — andere Antwort probieren", 2000);
        }

        setPassBusy(true);
        try {
            const err = await rpcAttemptPass(code, mePlayerId, clean);
            if (err) return showToast(`❌ ${err.message}`, 2400);
            setAnswerDraft("");
            showToast("⏳ Wird geprüft …", 900);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2400);
        } finally {
            setPassBusy(false);
        }
    }, [mePlayerId, lobby, iAmEliminated, isMeHolder, passBusy, code, answerDraft, rpcAttemptPass, showToast]);

    // Topic-Mechanik B: Mitspieler stimmt ab, ob die Antwort gilt.
    const handleVoteAnswer = useCallback(
        async (accept: boolean) => {
            if (!mePlayerId) return showToast("⚠️ Keine Player-ID", 1800);
            if (!passAttempt.attempt) return;
            if (passAttempt.attempt.holder_player_id === mePlayerId) return;
            if (passAttempt.myVote !== null) return showToast("Du hast schon abgestimmt", 1400);
            if (voteBusyAttempt) return;

            setVoteBusyAttempt(true);
            try {
                const err = await rpcVoteAnswer(passAttempt.attempt.id, mePlayerId, accept);
                if (err) return showToast(`❌ ${err.message}`, 2400);
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2400);
            } finally {
                setVoteBusyAttempt(false);
            }
        },
        [mePlayerId, passAttempt, voteBusyAttempt, rpcVoteAnswer, showToast]
    );

    // Rematch handler (also bound to "R" key)
    const handleRematch = useCallback(async () => {
        if (endActionBusy) return;
        if (!mePlayerId) return;
        setEndActionBusy("rematch");
        const { error } = await supabase.rpc("rpc_rematch", { p_code: code, p_player_id: mePlayerId });
        if (error) {
            setEndActionBusy(null);
            showToast(`❌ Rematch: ${error.message}`, 2400);
            return;
        }
        showToast("🔁 Rematch gestartet", 1200);
    }, [endActionBusy, mePlayerId, supabase, code, showToast]);

    // rematch_wait: Bereit-Toggle (gleiche RPC wie in der Lobby)
    const handleToggleReady = useCallback(async () => {
        if (!mePlayerId || !lobby) return;
        if (readyBusy) return;

        setReadyBusy(true);
        try {
            const { error } = await supabase.rpc("rpc_toggle_ready", {
                p_lobby_id: lobby.id,
                p_player_id: mePlayerId,
            });
            if (error) showToast(`❌ ${error.message}`, 2400);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2400);
        } finally {
            setReadyBusy(false);
        }
    }, [mePlayerId, lobby, readyBusy, supabase, showToast]);

    const allReadyForRematch = useMemo(() => {
        return players.length >= 2 && players.every((p) => !!p.ready);
    }, [players]);

    // rematch_wait: sobald alle bereit sind, Topic-Vote der nächsten Runde starten.
    useEffect(() => {
        if (!lobby) return;
        if (lobby.phase !== "rematch_wait") return;
        if (!allReadyForRematch) return;
        if (startRematchInFlightRef.current) return;

        startRematchInFlightRef.current = true;
        void (async () => {
            try {
                const { error } = await supabase.rpc("rpc_start_rematch_if_ready", { p_code: code });
                if (error) showToast(`❌ ${error.message}`, 2400);
            } finally {
                startRematchInFlightRef.current = false;
            }
        })();
    }, [lobby, allReadyForRematch, supabase, code, showToast]);

    // Keyboard shortcuts: Space (pass), 1/2/3 (vote), R (rematch), M (mute)
    useEffect(() => {
        const onKeyDown = (ev: KeyboardEvent) => {
            // Don't capture keys while typing in inputs
            const target = ev.target as HTMLElement | null;
            if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)) return;

            if (ev.key === "m" || ev.key === "M") {
                ev.preventDefault();
                // dynamic import to keep this small + not coupled to React state
                import("@/lib/gameFx").then(({ getMuted, setMuted, unlockGameFx }) => {
                    const next = !getMuted();
                    setMuted(next);
                    if (!next) unlockGameFx();
                });
                return;
            }

            if (!lobby) return;

            // Topic vote: 1 / 2 / 3
            if (lobby.phase === "topic_vote" && (ev.key === "1" || ev.key === "2" || ev.key === "3")) {
                ev.preventDefault();
                const choice = Number(ev.key) as 1 | 2 | 3;
                void vote(choice);
                return;
            }

            // Running: Space ist deaktiviert (Halter muss Antwort eingeben).
            // Enter im Antwort-Input löst handleAttemptPass aus — siehe Running-UI.

            // Finished: R triggers rematch
            if (lobby.phase === "finished" && (ev.key === "r" || ev.key === "R")) {
                ev.preventDefault();
                void handleRematch();
                return;
            }
        };

        window.addEventListener("keydown", onKeyDown, { passive: false });
        return () => window.removeEventListener("keydown", onKeyDown);
    }, [lobby, vote, handleRematch]);

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

    if (!lobby)
        return (
            <main style={{ minHeight: "100vh", display: "grid", placeItems: "center", padding: 24, color: "white" }}>
                <Spinner size={28} label="Lade Spiel…" />
            </main>
        );

    // Labels
    const aLabel = lobby.topic_a ?? "…";
    const bLabel = lobby.topic_b ?? "…";
    const rLabel = "Zufällig";

    // =========================================================
    // PHASE: TOPIC VOTE  (NO blinking)
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
                    color: "white",
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
                                <div className="cardHint">{myVote === 1 ? "Ausgewählt" : "Tippe zum Voten"}</div>
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
                                <div className="cardHint">{myVote === 2 ? "Ausgewählt" : "Tippe zum Voten"}</div>
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
                                <div className="cardHint">{myVote === 3 ? "Ausgewählt" : "Überraschen lassen"}</div>
                            </button>
                        </div>

                        <div className="statusLine">
                            {allVoted ? "✅ Alle haben gewählt – wird ausgewertet…" : "Wählt schnell – bei allen Votes geht’s sofort weiter."}
                        </div>

                        <ToastStack toasts={toasts} inline />
                    </div>
                </div>

                <div className="bottomBar" style={{ zIndex: 50 }}>
                    <div className="bottomInner">
                        <div className="bottomLeft">
                            <div className="brandMark">🥔</div>
                            <div className="bottomText">
                                <div className="bottomTitle">Countdown</div>
                                <div className="bottomSub">{myVote ? "Auswahl gesetzt." : "Tippe auf ein Thema."}</div>
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
          .kicker{font-size:12px;font-weight:950;letter-spacing:2.2px;opacity:.78;text-transform:uppercase;animation:${reduceMotion ? "none" : "fadeUp 700ms cubic-bezier(.2,.9,.2,1) both"};}
          .headline{margin-top:10px;font-size:clamp(36px,4.8vw,70px);font-weight:1000;letter-spacing:-0.6px;position:relative;display:inline-block;text-shadow:0 24px 80px rgba(0,0,0,0.35);animation:${reduceMotion ? "none" : "heroIn 900ms cubic-bezier(.16,1,.3,1) both"};}
          .headlineGlow{position:absolute;inset:-30px -60px;background:radial-gradient(circle at 40% 35%, rgba(255,214,10,0.25), rgba(255,149,0,0.18), rgba(255,45,85,0.06), transparent 70%);filter:blur(18px);opacity:.9;pointer-events:none;animation:${reduceMotion ? "none" : "glowFloat 4.2s ease-in-out infinite"};}
          .topicGrid{margin-top:24px;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px;}
          .glassCard{color:white;position:relative;width:100%;border-radius:38px;padding:24px 22px 22px;min-height:260px;text-align:left;cursor:pointer;border:1px solid rgba(255,255,255,0.18);background:linear-gradient(180deg, rgba(255,255,255,0.14), rgba(255,255,255,0.06)),radial-gradient(circle at 30% 20%, rgba(255,214,10,0.14), rgba(255,149,0,0.08), rgba(0,0,0,0.16) 70%);backdrop-filter:blur(16px) saturate(140%);-webkit-backdrop-filter:blur(16px) saturate(140%);box-shadow:0 18px 70px rgba(0,0,0,0.28),inset 0 1px 0 rgba(255,255,255,0.20);overflow:hidden;transform:translateZ(0);transition:transform .22s cubic-bezier(.2,1,.2,1), box-shadow .22s ease, border-color .22s ease, filter .22s ease;animation:${reduceMotion ? "none" : "cardIn 900ms cubic-bezier(.16,1,.3,1) both"};}
          .glassCard:nth-child(2){animation-delay:${reduceMotion ? "0ms" : "70ms"};}
          .glassCard:nth-child(3){animation-delay:${reduceMotion ? "0ms" : "140ms"};}
          .glassCard:hover{transform:scale(1.035);border-color:rgba(255,255,255,0.30);box-shadow:0 26px 90px rgba(0,0,0,0.34),inset 0 1px 0 rgba(255,255,255,0.22);filter:brightness(1.03);}
          .glassCard:active{transform:scale(1.015);}
          .glassCard:disabled{opacity:.78;cursor:not-allowed;transform:none;filter:none;}
          .glassShine{position:absolute;inset:-120px;background:radial-gradient(circle at 20% 20%, rgba(255,255,255,0.24), rgba(255,255,255,0.06), transparent 60%);opacity:.75;filter:blur(18px);pointer-events:none;animation:${reduceMotion ? "none" : "shineSweep 5.2s ease-in-out infinite"};}
          .cardTop{display:flex;justify-content:space-between;align-items:center;gap:10px;position:relative;z-index:2;}
          .chip{display:inline-flex;align-items:center;justify-content:center;height:38px;padding:0 14px;border-radius:999px;font-weight:1000;background:rgba(0,0,0,0.18);border:1px solid rgba(255,255,255,0.16);box-shadow:inset 0 1px 0 rgba(255,255,255,0.12);}
          .micro{font-size:12px;font-weight:950;letter-spacing:1.2px;opacity:.82;text-transform:uppercase;}
          .cardTitle{margin-top:20px;font-size:clamp(24px,2.8vw,40px);font-weight:1000;letter-spacing:-0.2px;position:relative;z-index:2;text-shadow:0 18px 60px rgba(0,0,0,0.26);}
          .cardHint{margin-top:12px;font-size:13px;font-weight:900;opacity:.85;position:relative;z-index:2;}

          /* ✅ PERMA GREEN OUTLINE (NO blink/pulse) */
          .glassCard.active{
            outline: 3px solid rgba(52,199,89,0.95);
            outline-offset: 2px;
            border-color: rgba(52,199,89,0.65);
            box-shadow:
              0 30px 110px rgba(0,0,0,0.40),
              0 0 0 2px rgba(52,199,89,0.28) inset,
              0 0 46px rgba(52,199,89,0.22);
            background:
              radial-gradient(circle at 18% 18%, rgba(52,199,89,0.20), rgba(0,0,0,0.10) 58%),
              linear-gradient(135deg, rgba(52,199,89,0.14), rgba(255,255,255,0.08), rgba(0,0,0,0.10));
            filter: brightness(1.06) saturate(1.06);
          }

          .statusLine{margin-top:14px;font-weight:900;opacity:.88;font-size:13px;animation:${reduceMotion ? "none" : "fadeUp 520ms ease both"};}
          .toastInline{margin-top:14px;font-weight:950;opacity:.92;animation:${reduceMotion ? "none" : "fadeUp 480ms ease both"};}

          .bottomBar{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);width:min(980px,94vw);}
          .bottomInner{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:14px 14px;border-radius:999px;background:rgba(0,0,0,0.26);border:1px solid rgba(255,255,255,0.16);backdrop-filter:blur(14px) saturate(140%);-webkit-backdrop-filter:blur(14px) saturate(140%);box-shadow:0 18px 80px rgba(0,0,0,0.34), inset 0 1px 0 rgba(255,255,255,0.14);animation:${reduceMotion ? "none" : "dockIn 900ms cubic-bezier(.16,1,.3,1) both"};animation-delay:${reduceMotion ? "0ms" : "120ms"};}
          .bottomLeft{display:flex;align-items:center;gap:10px;min-width:220px;}
          .brandMark{width:40px;height:40px;border-radius:999px;display:grid;place-items:center;background:radial-gradient(circle at 30% 30%, rgba(255,255,255,0.16), rgba(0,0,0,0.18));border:1px solid rgba(255,255,255,0.14);box-shadow:0 10px 30px rgba(0,0,0,0.22);}
          .bottomTitle{font-weight:1000;letter-spacing:1.2px;font-size:12px;text-transform:uppercase;opacity:.9;}
          .bottomSub{font-weight:850;opacity:.78;font-size:12px;margin-top:2px;}
          .barWrap{flex:1;min-width:180px;position:relative;}
          .barTrack{height:12px;border-radius:999px;background:rgba(255,255,255,0.10);border:1px solid rgba(255,255,255,0.12);overflow:hidden;}
          .barFill{height:100%;background:linear-gradient(90deg, rgba(255,214,10,0.95), rgba(255,149,0,0.95), rgba(255,45,85,0.80));filter:saturate(120%);}
          .barGlow{position:absolute;inset:-18px -22px;background:radial-gradient(circle at 50% 50%, rgba(255,214,10,0.18), rgba(255,149,0,0.14), rgba(255,45,85,0.06), transparent 70%);filter:blur(18px);opacity:.9;pointer-events:none;animation:${reduceMotion ? "none" : "glowFloat 3.6s ease-in-out infinite"};}
          .timeBox{min-width:70px;height:40px;border-radius:999px;display:grid;place-items:center;font-size:18px;font-weight:1000;background:rgba(255,255,255,0.10);border:1px solid rgba(255,255,255,0.14);box-shadow:inset 0 1px 0 rgba(255,255,255,0.12);}
          .grain{position:absolute;inset:0;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='120' height='120' filter='url(%23n)' opacity='.35'/%3E%3C/svg%3E");opacity:.10;mix-blend-mode:overlay;pointer-events:none;}
          .orbs{position:absolute;inset:0;pointer-events:none;overflow:hidden;}
          .orb{position:absolute;border-radius:999px;filter:blur(24px);opacity:.75;mix-blend-mode:screen;}
          .o1{width:420px;height:420px;left:-120px;top:-120px;background:radial-gradient(circle at 30% 30%, rgba(255,214,10,0.26), rgba(255,149,0,0.18), transparent 70%);animation:${reduceMotion ? "none" : "orbFloat 8s ease-in-out infinite"};}
          .o2{width:360px;height:360px;right:-120px;top:40px;background:radial-gradient(circle at 30% 30%, rgba(34,211,238,0.18), rgba(167,139,250,0.12), transparent 72%);animation:${reduceMotion ? "none" : "orbFloat 9.5s ease-in-out infinite"};animation-delay:${reduceMotion ? "0s" : "-1.2s"};}
          .o3{width:520px;height:520px;left:20%;bottom:-220px;background:radial-gradient(circle at 30% 30%, rgba(255,45,85,0.14), rgba(255,149,0,0.16), transparent 70%);animation:${reduceMotion ? "none" : "orbFloat 10.5s ease-in-out infinite"};animation-delay:${reduceMotion ? "0s" : "-2.1s"};}
          @keyframes fadeUp{from{opacity:0;transform:translateY(10px);}to{opacity:1;transform:translateY(0);}}
          @keyframes heroIn{0%{opacity:0;transform:translateY(12px) scale(0.985);filter:blur(1px);}100%{opacity:1;transform:translateY(0) scale(1);filter:blur(0);}}
          @keyframes cardIn{0%{opacity:0;transform:translateY(16px) scale(0.985);}100%{opacity:1;transform:translateY(0) scale(1);}}
          @keyframes dockIn{0%{opacity:0;transform:translateY(16px);}100%{opacity:1;transform:translateY(0);}}
          @keyframes glowFloat{0%,100%{transform:translateY(0);opacity:.82;}50%{transform:translateY(-6px);opacity:1;}}
          @keyframes shineSweep{0%,100%{transform:translateX(-10px) rotate(12deg);opacity:.60;}50%{transform:translateX(18px) rotate(12deg);opacity:.90;}}
          @keyframes orbFloat{0%,100%{transform:translateY(0) translateX(0);}50%{transform:translateY(18px) translateX(10px);}}
          @media (max-width: 980px){ .glassCard{ min-height: 230px; } }
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
                    color: "white",
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(52,199,89,0.22) 0%, rgba(0,120,45,0.68) 80%)",
                }}
            >
                <div style={{ width: "min(1100px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>THEMA GEWÄHLT</div>

                    <div style={{ marginTop: 16, display: "grid", gridTemplateColumns: "repeat(3, minmax(0,1fr))", gap: 14, alignItems: "stretch" }}>
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
                    <div style={{ marginTop: 10, fontSize: "clamp(80px, 10vw, 140px)", fontWeight: 950, letterSpacing: 2, textShadow: "0 18px 70px rgba(0,0,0,0.35)" }}>
                        {Math.max(0, countdownSecondsLeft ?? 5)}
                    </div>

                    <ToastStack toasts={toasts} inline />
                </div>

                <style>{`
          .resultTile{border-radius:28px;border:1px solid rgba(255,255,255,0.14);background:rgba(0,0,0,0.18);padding:16px 14px;text-align:left;backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);overflow:hidden;position:relative;transform-origin:center;}
          .resultBadge{display:inline-flex;align-items:center;justify-content:center;height:34px;padding:0 12px;border-radius:999px;font-weight:950;background:rgba(255,255,255,0.12);border:1px solid rgba(255,255,255,0.14);}
          .resultTitle{margin-top:14px;font-size:clamp(18px,2.2vw,28px);font-weight:950;text-shadow:0 10px 30px rgba(0,0,0,0.22);}
          @keyframes winPop {0%{transform:scale(1);filter:brightness(1);}70%{transform:scale(1.06);filter:brightness(1.18);}100%{transform:scale(1.04);filter:brightness(1.12);}}
          @keyframes loseSlide {0%{transform:scale(1);opacity:1;}100%{transform:translateY(14px) scale(0.92);opacity:0.12;}}
          .resultTile.win{background:radial-gradient(circle at 30% 30%, rgba(255,255,255,0.16), rgba(0,0,0,0.18)),linear-gradient(135deg, rgba(52,199,89,0.18), rgba(10,132,255,0.10), rgba(255,214,10,0.12));border-color:rgba(255,255,255,0.28);box-shadow:0 18px 70px rgba(0,0,0,0.25);animation:winPop .55s ease-out forwards;}
          .resultTile.lose{animation:loseSlide .55s ease-out forwards;}
          @media (max-width: 860px){ main div[style*="gridTemplateColumns: repeat(3"]{ grid-template-columns: 1fr !important; } }
        `}</style>
            </main>
        );
    }

    // =========================================================
    // PHASE: FINISHED  (Winner-only hero, NO Top3 podium)
    // - Awards: Fastest Pass + Longest Hold
    // - Ranking: # | Name | Score | Fastest
    // =========================================================
    if (lobby.phase === "finished") {
        const winnerName = winnerPlayer?.name ?? "Unbekannt";
        const shown = showFullRanking ? ranking : top5;

        const fastestOverall =
            [...ranking].filter((r) => r.fastest != null).sort((a, b) => (a.fastest ?? 9e9) - (b.fastest ?? 9e9))[0] ?? null;

        const longestHold = [...ranking].sort((a, b) => (b.holdMs ?? 0) - (a.holdMs ?? 0))[0] ?? null;

        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    color: "white",
                    position: "relative",
                    overflow: "hidden",
                    background:
                        "radial-gradient(circle at 50% 12%, rgba(255,255,255,0.12) 0%, rgba(0,0,0,0.22) 56%)," +
                        "radial-gradient(circle at 20% 18%, rgba(34,211,238,0.14) 0%, rgba(0,0,0,0) 52%)," +
                        "radial-gradient(circle at 82% 22%, rgba(167,139,250,0.12) 0%, rgba(0,0,0,0) 52%)," +
                        "radial-gradient(circle at 50% 88%, rgba(255,214,10,0.34) 0%, rgba(240,138,26,0.58) 40%, rgba(143,15,15,0.92) 100%)",
                }}
            >
                <AchievementToastPortal achievements={newAchievements} onDismiss={dismissAchievement} />
                <Confetti active />
                <BackdropFx variant="warm" rays vignette />

                <div style={{ width: "min(1180px, 96vw)", position: "relative", zIndex: 2 }}>
                    {/* HERO (Winner only) */}
                    <div className="finishHero">
                        <div className="finishKicker">SPIEL BEENDET</div>

                        <div className="finishWinner">
                            <span className="trophy" aria-hidden>
                                🏆
                            </span>
                            <span className="winnerName">{winnerName}</span>
                            <span className="winnerGlow" aria-hidden />
                        </div>

                        <div className="finishMeta">
                            <span className="metaPill">
                                Runden <b>{lobby.round_number ?? "—"}</b>
                            </span>
                            <span className="metaPill">
                                Thema <b>{selectedTopic}</b>
                            </span>
                            {myRankRow ? (
                                <span className="metaPill metaMe">
                                    Du <b>#{myRankRow.rank}</b>
                                </span>
                            ) : null}
                        </div>
                    </div>

                    {/* MAIN GRID */}
                    <div className="finishGrid" style={{ marginTop: 18 }}>
                        {/* Ranking */}
                        <div className="card">
                            <div className="cardTitle">🏅 Ranking</div>

                            <div className="table">
                                <div className="row head">
                                    <div>#</div>
                                    <div>Player</div>
                                    <div className="r">Score</div>
                                    <div className="r">Fastest</div>
                                </div>

                                {shown.map((p, idx) => (
                                    <div key={p.player_id} className={`row ${p.player_id === mePlayerId ? "me" : ""}`}>
                                        <div>{idx + 1}</div>
                                        <div className="name">
                                            {p.name}
                                            {!p.is_alive ? <span className="tag dead">💀</span> : null}
                                            {p.player_id === lobby.holder_player_id ? <span className="tag holder">🥔</span> : null}
                                        </div>
                                        <div className="r">
                                            <b>{p.score}</b>
                                        </div>
                                        <div className="r">{fmtMs(p.fastest)}</div>
                                    </div>
                                ))}
                            </div>

                            <div className="cardActions">
                                <button className="btn btnSecondary" type="button" onClick={() => setShowFullRanking((v) => !v)}>
                                    {showFullRanking ? "Nur Top 5" : "Alle anzeigen"}
                                </button>
                            </div>
                        </div>

                        {/* Awards + Actions */}
                        <div className="card">
                            <div className="cardTitle">🎖 Awards</div>

                            <div className="awards">
                                <div className="awardTile">
                                    <div className="awardK">⚡ Fastest Pass</div>
                                    <div className="awardV">
                                        {fastestOverall ? (
                                            <>
                                                <b>{fastestOverall.name}</b>
                                                <span className="sep">•</span>
                                                <span>{fmtMs(fastestOverall.fastest)}</span>
                                            </>
                                        ) : (
                                            "—"
                                        )}
                                    </div>
                                    <div className="awardS">Schnellste Reaktion im Match</div>
                                    <span className="awardGlow g1" aria-hidden />
                                </div>

                                <div className="awardTile">
                                    <div className="awardK">🧱 Longest Hold</div>
                                    <div className="awardV">
                                        {longestHold ? (
                                            <>
                                                <b>{longestHold.name}</b>
                                                <span className="sep">•</span>
                                                <span>{fmtHold(longestHold.holdMs)}</span>
                                            </>
                                        ) : (
                                            "—"
                                        )}
                                    </div>
                                    <div className="awardS">Längste Haltezeit insgesamt</div>
                                    <span className="awardGlow g2" aria-hidden />
                                </div>
                            </div>

                            <div className="cardTitle" style={{ marginTop: 18 }}>🎖 Jede Auszeichnung</div>
                            <div className="personalAwards">
                                {ranking.map((r) => {
                                    const a = playerAwards.get(r.player_id);
                                    if (!a) return null;
                                    return (
                                        <div key={r.player_id} className={`personalAwardRow ${r.player_id === mePlayerId ? "me" : ""}`}>
                                            <span className="personalAwardIcon" aria-hidden>{a.icon}</span>
                                            <span className="personalAwardName">{r.name}</span>
                                            <span className="personalAwardLabel">{a.label}</span>
                                            <span className="personalAwardValue">{a.value}</span>
                                        </div>
                                    );
                                })}
                            </div>

                            <div className="cardActions" style={{ marginTop: 14 }}>
                                <button
                                    className="btn btnPrimary"
                                    onClick={async () => {
                                        if (endActionBusy) return;
                                        if (!mePlayerId) return;
                                        setEndActionBusy("reset");
                                        const { error } = await supabase.rpc("rpc_reset_lobby", { p_code: code, p_player_id: mePlayerId });
                                        if (error) {
                                            setEndActionBusy(null);
                                            return showToast(`❌ Reset: ${error.message}`, 2400);
                                        }
                                        window.location.href = `/lobby/${encodeURIComponent(code)}`;
                                    }}
                                    type="button"
                                    disabled={!!endActionBusy}
                                >
                                    {endActionBusy === "reset" ? <Spinner size={16} label="Lade…" /> : "Zurück zur Lobby"}
                                </button>

                                <button
                                    className="btn btnSecondary"
                                    onClick={async () => {
                                        if (endActionBusy) return;
                                        if (!mePlayerId) return;
                                        setEndActionBusy("rematch");
                                        const { error } = await supabase.rpc("rpc_rematch", { p_code: code, p_player_id: mePlayerId });
                                        if (error) {
                                            setEndActionBusy(null);
                                            return showToast(`❌ Rematch: ${error.message}`, 2400);
                                        }
                                        showToast("🔁 Rematch gestartet", 1200);
                                        // Realtime / polling will move us to topic_vote phase shortly.
                                    }}
                                    type="button"
                                    disabled={!!endActionBusy}
                                    title="Direkt nochmal (Taste R)"
                                >
                                    {endActionBusy === "rematch" ? <Spinner size={16} label="Starte…" /> : "🔁 Rematch (R)"}
                                </button>
                            </div>

                            <ToastStack toasts={toasts} inline />
                        </div>
                    </div>
                </div>

                <style>{`
        .finishHero{ text-align:center; }
        .finishKicker{
          font-size:12px;
          font-weight:950;
          letter-spacing:2.2px;
          opacity:.78;
          animation: fadeUp 600ms ease both;
        }
        .finishWinner{
          margin-top: 10px;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          gap: 14px;
          position:relative;
          animation: heroIn 900ms cubic-bezier(.16,1,.3,1) both;
        }
        .trophy{
          width: 54px; height: 54px;
          display:grid; place-items:center;
          border-radius: 999px;
          background: rgba(0,0,0,0.22);
          border: 1px solid rgba(255,255,255,0.14);
          box-shadow: inset 0 1px 0 rgba(255,255,255,0.10), 0 18px 60px rgba(0,0,0,0.28);
          font-size: 28px;
        }
        .winnerName{
          font-size: clamp(44px, 5.2vw, 86px);
          font-weight: 1000;
          letter-spacing: -0.9px;
          text-shadow: 0 24px 90px rgba(0,0,0,0.38);
        }
        .winnerGlow{
          position:absolute;
          inset: -40px -70px;
          background: radial-gradient(circle at 40% 35%, rgba(255,214,10,0.22), rgba(34,211,238,0.14), rgba(255,45,85,0.08), transparent 70%);
          filter: blur(18px);
          opacity: .95;
          pointer-events:none;
          animation: glowFloat 4.4s ease-in-out infinite;
        }
        .finishMeta{
          margin-top: 12px;
          display:flex;
          justify-content:center;
          flex-wrap:wrap;
          gap:10px;
          animation: fadeUp 720ms ease both;
          animation-delay: 120ms;
        }
        .metaPill{
          padding: 10px 12px;
          border-radius: 999px;
          background: rgba(0,0,0,0.24);
          border: 1px solid rgba(255,255,255,0.14);
          backdrop-filter: blur(12px);
          -webkit-backdrop-filter: blur(12px);
          font-weight: 900;
          opacity: .95;
        }
        .metaMe{
          border-color: rgba(34,211,238,0.22);
          background: radial-gradient(circle at 20% 20%, rgba(34,211,238,0.10), rgba(0,0,0,0.22));
        }

        .finishGrid{
          display:grid;
          grid-template-columns: 1.3fr 1fr;
          gap: 14px;
          align-items:start;
        }
        .card{
          border-radius: 28px;
          background: rgba(0,0,0,0.22);
          border: 1px solid rgba(255,255,255,0.14);
          backdrop-filter: blur(12px);
          -webkit-backdrop-filter: blur(12px);
          padding: 16px;
          box-shadow: 0 18px 70px rgba(0,0,0,0.28), inset 0 1px 0 rgba(255,255,255,0.12);
          animation: fadeUp 780ms ease both;
          animation-delay: 160ms;
        }
        .cardTitle{
          font-weight: 1000;
          letter-spacing: .2px;
          opacity: .95;
          text-align:left;
        }

        .table{ margin-top: 12px; display:grid; gap: 8px; }
        .row{
          display:grid;
          grid-template-columns: 42px 1fr 100px 120px;
          gap: 10px;
          padding: 10px 10px;
          border-radius: 16px;
          background: rgba(255,255,255,0.06);
          border: 1px solid rgba(255,255,255,0.08);
          align-items:center;
        }
        .row.head{
          background: rgba(255,255,255,0.04);
          border-color: rgba(255,255,255,0.06);
          font-size: 12px;
          font-weight: 950;
          letter-spacing: 1.2px;
          text-transform: uppercase;
          opacity: .86;
        }
        .row.me{
          border-color: rgba(34,211,238,0.22);
          background: radial-gradient(circle at 20% 20%, rgba(34,211,238,0.10), rgba(255,255,255,0.06));
        }
        .name{
          display:flex;
          gap: 8px;
          align-items:center;
          font-weight: 950;
          overflow:hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .r{ text-align:right; font-weight: 900; opacity: .92; }
        .tag{
          display:inline-flex;
          align-items:center;
          justify-content:center;
          padding: 2px 8px;
          border-radius: 999px;
          font-size: 12px;
          font-weight: 950;
          border: 1px solid rgba(255,255,255,0.14);
          background: rgba(0,0,0,0.18);
        }
        .tag.dead{ opacity: .75; }
        .tag.holder{ background: rgba(255,214,10,0.16); }

        .awards{ margin-top: 12px; display:grid; gap: 10px; }
        .awardTile{
          position:relative;
          padding: 14px 14px 12px;
          border-radius: 22px;
          background: rgba(255,255,255,0.06);
          border: 1px solid rgba(255,255,255,0.08);
          text-align:left;
          overflow:hidden;
          box-shadow: inset 0 1px 0 rgba(255,255,255,0.10);
        }
        .awardK{
          font-size: 12px;
          font-weight: 1000;
          letter-spacing: 1.6px;
          opacity: .78;
          text-transform: uppercase;
        }
        .awardV{
          margin-top: 10px;
          font-size: 18px;
          font-weight: 950;
          letter-spacing: -0.2px;
          display:flex;
          flex-wrap: wrap;
          gap: 8px;
          align-items: baseline;
        }
        .sep{ opacity: .55; }
        .awardS{
          margin-top: 6px;
          font-size: 12px;
          font-weight: 850;
          opacity: .74;
        }
        .awardGlow{
          position:absolute;
          inset:-50px -70px;
          filter: blur(18px);
          opacity: .70;
          pointer-events:none;
          animation: glowFloat 4.2s ease-in-out infinite;
        }
        .awardGlow.g1{ background: radial-gradient(circle at 30% 25%, rgba(34,211,238,0.16), rgba(255,255,255,0.06), transparent 70%); }
        .awardGlow.g2{
          background: radial-gradient(circle at 30% 25%, rgba(52,199,89,0.14), rgba(255,214,10,0.10), transparent 72%);
          animation-delay: -1.4s;
        }

        .personalAwards{ margin-top: 10px; display: grid; gap: 6px; max-height: 220px; overflow-y: auto; }
        .personalAwardRow{
          display: grid;
          grid-template-columns: 24px 1fr auto;
          grid-template-areas: "icon name value" "icon label value";
          column-gap: 10px;
          row-gap: 1px;
          padding: 8px 10px;
          border-radius: 12px;
          background: rgba(0,0,0,0.18);
          border: 1px solid rgba(255,255,255,0.08);
        }
        .personalAwardRow.me{ border-color: rgba(255,214,10,0.6); background: rgba(255,214,10,0.08); }
        .personalAwardIcon{ grid-area: icon; font-size: 18px; align-self: center; }
        .personalAwardName{ grid-area: name; font-weight: 900; font-size: 13px; }
        .personalAwardLabel{ grid-area: label; font-size: 11px; opacity: 0.75; }
        .personalAwardValue{ grid-area: value; align-self: center; font-weight: 800; font-size: 13px; opacity: 0.9; }

        .cardActions{
          margin-top: 12px;
          display:flex;
          gap: 10px;
          justify-content:flex-start;
          flex-wrap:wrap;
        }
        .btn{
          appearance:none;
          border: 1px solid rgba(255,255,255,0.14);
          background: rgba(0,0,0,0.22);
          color: white;
          border-radius: 999px;
          padding: 10px 14px;
          font-weight: 950;
          cursor: pointer;
          transition: transform .14s ease, filter .14s ease, border-color .14s ease;
          box-shadow: inset 0 1px 0 rgba(255,255,255,0.10);
        }
        .btn:hover{ transform: translateY(-1px); filter: brightness(1.06); border-color: rgba(255,255,255,0.22); }
        .btn:active{ transform: translateY(0px) scale(0.99); }
        .btnPrimary{ background: linear-gradient(180deg, rgba(11,10,138,0.95), rgba(4,4,94,0.95)); }
        .btnSecondary{ background: rgba(0,0,0,0.22); }

        @keyframes fadeUp{ from{ opacity:0; transform: translateY(10px); } to{ opacity:1; transform: translateY(0); } }
        @keyframes heroIn{
          0%{ opacity:0; transform: translateY(14px) scale(.985); filter: blur(1px); }
          100%{ opacity:1; transform: translateY(0) scale(1); filter: blur(0); }
        }
        @keyframes glowFloat{
          0%,100%{ transform: translateY(0); opacity:.75; }
          50%{ transform: translateY(-6px); opacity:1; }
        }
        @media (max-width: 980px){ .finishGrid{ grid-template-columns: 1fr; } }
      `}</style>
            </main>
        );
    }

    // =========================================================
    // PHASE: REMATCH_WAIT
    // =========================================================
    // rpc_rematch setzt diese Phase; vorher gab es dafür keinen eigenen
    // Screen (sie fiel in den generischen "WARTEN"-Fallback), und
    // rpc_start_rematch_if_ready wurde nie aufgerufen -> das Spiel blieb
    // nach einem Rematch-Klick für immer hier stehen.
    if (lobby.phase === "rematch_wait") {
        const meReady = !!meRow?.ready;

        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    color: "white",
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(52,199,89,0.22) 0%, rgba(0,120,45,0.68) 80%)",
                }}
            >
                <div style={{ width: "min(680px, 96vw)", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>REMATCH</div>
                    <div style={{ fontSize: "clamp(26px, 4vw, 42px)", fontWeight: 950, marginTop: 12 }}>🔁 Bereit für die nächste Runde?</div>
                    <div style={{ marginTop: 8, opacity: 0.82, fontWeight: 700 }}>
                        Sobald alle bereit sind, geht’s automatisch weiter zur Themenwahl.
                    </div>

                    <div style={{ marginTop: 22, display: "grid", gap: 8 }}>
                        {players.map((p) => (
                            <div
                                key={p.player_id}
                                style={{
                                    display: "flex",
                                    alignItems: "center",
                                    justifyContent: "space-between",
                                    padding: "10px 14px",
                                    borderRadius: 14,
                                    background: "rgba(0,0,0,0.22)",
                                    border: "1px solid rgba(255,255,255,0.14)",
                                    fontWeight: 800,
                                }}
                            >
                                <span>
                                    {p.name}
                                    {mePlayerId === p.player_id ? " (du)" : ""}
                                </span>
                                <span>{p.ready ? "✅ Bereit" : "⏳ Wartet"}</span>
                            </div>
                        ))}
                    </div>

                    <div style={{ marginTop: 20 }}>
                        <button
                            type="button"
                            className="btn btnPrimary"
                            onClick={() => void handleToggleReady()}
                            disabled={readyBusy || !mePlayerId}
                        >
                            {readyBusy ? <Spinner size={16} label="…" /> : meReady ? "❌ Nicht mehr bereit" : "✅ Bereit"}
                        </button>
                    </div>

                    <ToastStack toasts={toasts} inline />
                </div>

                <style>{`
          .btn{
            appearance:none;
            border: 1px solid rgba(255,255,255,0.14);
            background: rgba(0,0,0,0.22);
            color: white;
            border-radius: 999px;
            padding: 10px 18px;
            font-weight: 950;
            cursor: pointer;
            transition: transform .14s ease, filter .14s ease, border-color .14s ease;
            box-shadow: inset 0 1px 0 rgba(255,255,255,0.10);
          }
          .btn:hover{ transform: translateY(-1px); filter: brightness(1.06); border-color: rgba(255,255,255,0.22); }
          .btn:active{ transform: translateY(0px) scale(0.99); }
          .btn:disabled{ opacity: .7; cursor: not-allowed; transform: none; }
          .btnPrimary{ background: linear-gradient(180deg, rgba(11,10,138,0.95), rgba(4,4,94,0.95)); }
        `}</style>
            </main>
        );
    }

    // =========================================================
    // PHASE: NOT RUNNING
    // =========================================================
    if (lobby.phase !== "running") {
        return (
            <main
                style={{
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    color: "white",
                    background:
                        "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.10) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(243,168,59,0.35) 0%, rgba(192,106,0,0.70) 80%)",
                }}
            >
                <div style={{ width: "min(820px, 96vw)", textAlign: "center" }}>
                    {players.length === 0 || (players.length === 1 && !!mePlayerId && players[0]?.player_id === mePlayerId) ? (
                        <>
                            <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>NIEMAND DA</div>
                            <div style={{ fontSize: "clamp(28px, 4vw, 46px)", fontWeight: 950, marginTop: 12 }}>👻 Lobby leer</div>
                            <div style={{ marginTop: 10, opacity: 0.82, fontWeight: 700 }}>Alle anderen sind weg. Zurück zur Lobby?</div>
                            <div style={{ marginTop: 18 }}>
                                <a className="btn btnPrimary" href={`/lobby/${encodeURIComponent(code)}`}>← Zur Lobby</a>
                            </div>
                        </>
                    ) : (
                        <>
                            <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>WARTEN</div>
                            <div style={{ fontSize: "clamp(28px, 4vw, 46px)", fontWeight: 950, marginTop: 12 }}>
                                <Spinner size={28} label="Warten…" />
                            </div>
                            <div style={{ marginTop: 10, opacity: 0.78, fontWeight: 700 }}>Der Host startet gleich das Spiel.</div>
                        </>
                    )}
                </div>
                <ToastStack toasts={toasts} />
            </main>
        );
    }

    // =========================================================
    // PHASE: RUNNING (MINIMAL names only + smooth swap)
    // =========================================================
    const runningBg = iAmEliminated
        ? "radial-gradient(circle at 50% 30%, rgba(255,255,255,0.08) 0%, rgba(0,0,0,0.35) 60%), radial-gradient(circle at 50% 85%, rgba(180,180,180,0.14) 0%, rgba(25,25,25,0.92) 80%)"
        : isMeHolder
            ? "radial-gradient(circle at 50% 35%, rgba(255,120,80,0.55) 0%, rgba(143,15,15,0.96) 72%)"
            : "radial-gradient(circle at 50% 35%, rgba(255,255,255,0.08) 0%, rgba(0,0,0,0.18) 58%), radial-gradient(circle at 50% 80%, rgba(52,199,89,0.26) 0%, rgba(0,130,60,0.78) 80%)";

    const passDisabledReason = iAmEliminated ? "Du bist raus" : !isMeHolder ? "Nicht dein Turn" : passBusy ? "Busy" : null;

    // Heat level: derived from time-to-explode + player count (low/mid/high)
    const heatLevel: "low" | "mid" | "high" = (() => {
        if (!lobby.explode_at) return "low";
        const ms = msUntil(lobby.explode_at);
        if (ms == null) return "low";
        const aliveCount = players.filter((p) => p.is_alive).length || 1;
        const scaledThresholdHigh = 4500 + Math.max(0, 8 - aliveCount) * 250;
        const scaledThresholdMid = 9000 + Math.max(0, 8 - aliveCount) * 400;
        if (ms <= scaledThresholdHigh) return "high";
        if (ms <= scaledThresholdMid) return "mid";
        return "low";
    })();

    const heatStyle: Record<typeof heatLevel, { label: string; color: string; glow: string }> = {
        low: { label: "🟢 Ruhig", color: "rgba(52,199,89,0.78)", glow: "0 0 12px rgba(52,199,89,0.32)" },
        mid: { label: "🟠 Heiß", color: "rgba(255,149,0,0.85)", glow: "0 0 18px rgba(255,149,0,0.42)" },
        high: { label: "🔴 KRITISCH", color: "rgba(255,69,58,0.92)", glow: "0 0 26px rgba(255,69,58,0.56)" },
    };

    return (
        <main
            className={selfShake ? "kumpirSelfShake" : ""}
            style={{ minHeight: "100vh", width: "100vw", position: "relative", overflow: "hidden", background: runningBg, color: "white" }}
        >
            <PlayerRing
                players={players}
                holderPlayerId={lobby.holder_player_id}
                mePlayerId={mePlayerId}
                passEvent={passEvent}
                explodedPlayerId={explodedPlayerId}
                disconnectedIds={disconnectedIds}
            />

            {turnOverlay ? (
                <div className="turnOverlay" role="status" aria-live="polite">
                    ✅ Du bist dran
                </div>
            ) : null}

            {/* Top-right: Modus + Heat + Connection + Audio */}
            <div className="topRight" aria-hidden={false}>
                <div className="modePill" title={GAME_MODES[(lobby.game_mode as GameMode) ?? "original"]?.desc ?? lobby.game_mode ?? "Original"}>
                    <span>{GAME_MODES[(lobby.game_mode as GameMode) ?? "original"]?.icon ?? "🥔"}</span>
                    <span>{GAME_MODES[(lobby.game_mode as GameMode) ?? "original"]?.label ?? lobby.game_mode ?? "Original"}</span>
                    {lobby.game_mode === "reverse" ? (
                        <span
                            className="modeArrow"
                            aria-hidden
                            style={{ transform: `rotate(${(lobby.pass_direction ?? 1) < 0 ? 180 : 0}deg)` }}
                        >
                            ➜
                        </span>
                    ) : null}
                </div>
                <div
                    className={`heatPill heat-${heatLevel}`}
                    style={{ background: heatStyle[heatLevel].color, boxShadow: heatStyle[heatLevel].glow }}
                    title="Hitzelevel"
                >
                    {heatStyle[heatLevel].label}
                </div>
                <ConnectionPill status={realtimeStatus} onlyOnIssue />
                <AudioControl />
            </div>

            {/* Self-elimination flash overlay */}
            {selfShake ? <div className="selfFlash" aria-hidden /> : null}

            <ToastStack toasts={toasts} />

            <div className="hud">
                <div className="hudInner">
                    <div className="topic">{selectedTopic}</div>

                    {MUSIC_PLAYLISTS[selectedTopic] ? <SongRound songId={lobby.current_song_id} /> : null}

                    <div className="strip" key={hudPulseNonce}>
                        <div className="now">
                            <span className="dotNow" aria-hidden />
                            <span className="label">JETZT</span>
                            <span className="name">{holderName}</span>
                        </div>

                        <div className="arrow" aria-hidden>
                            →
                        </div>

                        <div className="next">
                            <span className="label">DANACH</span>
                            <span className="name">{nextUp?.name ?? "—"}</span>
                        </div>
                    </div>

                    {/* Topic-Mechanik B: Antwort + Validierung */}
                    {iAmEliminated ? (
                        <div className="hint">Du schaust zu.</div>
                    ) : passAttempt.attempt ? (
                        // ─── Es läuft gerade ein Validierungs-Versuch ───
                        isMeHolder ? (
                            <div className="answerStatus">
                                <div className="answerStatusLabel">Deine Antwort wird geprüft</div>
                                <div className="answerStatusValue">{`„${passAttempt.attempt.answer}"`}</div>
                                <div className="voteCounters">
                                    <span className="voteCounter accept">✅ {passAttempt.attempt.accept_count}</span>
                                    <span className="voteCounter reject">❌ {passAttempt.attempt.reject_count}</span>
                                </div>
                            </div>
                        ) : (
                            <div className="answerVote">
                                <div className="answerStatusLabel">{holderName} sagt:</div>
                                <div className="answerStatusValue">{`„${passAttempt.attempt.answer}"`}</div>
                                {passAttempt.myVote === null ? (
                                    <div className="actions" style={{ gap: 12 }}>
                                        <button
                                            type="button"
                                            className="btn btnReadyOn"
                                            onClick={() => void handleVoteAnswer(true)}
                                            disabled={voteBusyAttempt}
                                            title="Antwort akzeptieren"
                                        >
                                            ✅ Gilt
                                        </button>
                                        <button
                                            type="button"
                                            className="btn btnReadyOff"
                                            onClick={() => void handleVoteAnswer(false)}
                                            disabled={voteBusyAttempt}
                                            title="Antwort ablehnen"
                                        >
                                            ❌ Gilt nicht
                                        </button>
                                    </div>
                                ) : (
                                    <div className="hint">Du hast {passAttempt.myVote ? "✅ akzeptiert" : "❌ abgelehnt"}.</div>
                                )}
                                <div className="voteCounters">
                                    <span className="voteCounter accept">✅ {passAttempt.attempt.accept_count}</span>
                                    <span className="voteCounter reject">❌ {passAttempt.attempt.reject_count}</span>
                                </div>
                            </div>
                        )
                    ) : isMeHolder ? (
                        // ─── Halter darf neue Antwort eingeben ───
                        <div className="answerInputBox">
                            {lobby?.answer_mode === "voice" ? (
                                <>
                                    <VoiceInput
                                        variant="primary"
                                        disabled={!!passDisabledReason}
                                        onResult={(text) => setAnswerDraft(text.slice(0, 60))}
                                    />
                                    <div className="fieldHelp" style={{ textAlign: "center", marginBottom: 6, opacity: 0.75 }}>
                                        {answerDraft ? `Erkannt: „${answerDraft}"` : "…oder unten tippen"}
                                    </div>
                                </>
                            ) : null}
                            <div className="answerInputRow">
                                <input
                                    type="text"
                                    className="input answerInput"
                                    value={answerDraft}
                                    onChange={(e) => setAnswerDraft(e.target.value)}
                                    onKeyDown={(e) => {
                                        if (e.key === "Enter" && !passBusy) {
                                            e.preventDefault();
                                            void handleAttemptPass();
                                        }
                                    }}
                                    placeholder={`z.B. ${selectedTopic === "…" ? "deine Antwort" : "Antwort zu " + selectedTopic}`}
                                    maxLength={60}
                                    autoComplete="off"
                                    autoCapitalize="none"
                                    autoCorrect="off"
                                    spellCheck={false}
                                    inputMode="text"
                                    enterKeyHint="send"
                                />
                                {lobby?.answer_mode !== "voice" ? (
                                    <VoiceInput
                                        disabled={!!passDisabledReason}
                                        onResult={(text) => setAnswerDraft(text.slice(0, 60))}
                                    />
                                ) : null}
                            </div>
                            <button
                                type="button"
                                className="btn btnPrimary"
                                onClick={() => void handleAttemptPass()}
                                disabled={!!passDisabledReason || answerDraft.trim().length === 0}
                                title={passDisabledReason ?? "Antwort senden"}
                            >
                                {passBusy ? "…" : "🥔 Antworten + Passen"}
                            </button>
                        </div>
                    ) : (
                        <div className="hint">Warte, bis du dran bist.</div>
                    )}

                    {/* Used-Answers: bisher genannte Antworten dieser Runde */}
                    {lobby.used_answers && lobby.used_answers.length > 0 ? (
                        <div className="usedAnswers" aria-label="Bisher genannte Antworten">
                            <span className="usedAnswersLabel">Schon gesagt:</span>
                            {lobby.used_answers.slice(-6).map((a, i) => (
                                <span key={`${a}-${i}`} className="usedAnswerChip">{a}</span>
                            ))}
                            {lobby.used_answers.length > 6 ? (
                                <span className="usedAnswerChip more">+{lobby.used_answers.length - 6}</span>
                            ) : null}
                        </div>
                    ) : null}
                </div>
            </div>

            <style>{`
        .hud{
          position: relative;
          z-index: 3;
          min-height: 100vh;
          display: grid;
          place-items: center;
          padding: 22px;
        }
        .hudInner{
          width: min(920px, 94vw);
          display: grid;
          justify-items: center;
          gap: 14px;
          text-align: center;
        }
        .topic{
          font-size: clamp(22px, 3.6vw, 46px);
          font-weight: 950;
          text-shadow: 0 18px 70px rgba(0,0,0,0.35);
          opacity: .98;
        }

        .strip{
          width: min(920px, 94vw);
          border-radius: 999px;
          padding: 14px 16px;
          background: rgba(0,0,0,0.28);
          border: 1px solid rgba(255,255,255,0.14);
          backdrop-filter: blur(14px) saturate(140%);
          -webkit-backdrop-filter: blur(14px) saturate(140%);
          box-shadow: 0 22px 90px rgba(0,0,0,0.34), inset 0 1px 0 rgba(255,255,255,0.10);

          display: grid;
          grid-template-columns: 1fr auto 1fr;
          align-items: center;
          gap: 12px;

          animation: ${reduceMotion ? "none" : "stripSwap 520ms cubic-bezier(.16,1,.3,1) both"};
        }
        @keyframes stripSwap{
          0%{ opacity: 0; transform: translateY(8px) scale(.985); filter: blur(1px); }
          100%{ opacity: 1; transform: translateY(0) scale(1); filter: blur(0); }
        }

        .now,.next{
          display:flex;
          align-items: baseline;
          gap: 10px;
          justify-content: center;
          min-width: 0;
        }
        .dotNow{
          width: 10px;
          height: 10px;
          border-radius: 999px;
          background: rgba(52,199,89,0.95);
          box-shadow: 0 0 18px rgba(52,199,89,0.26);
          flex: 0 0 auto;
        }
        .label{
          font-size: 11px;
          font-weight: 950;
          letter-spacing: 1.6px;
          opacity: .72;
          text-transform: uppercase;
          flex: 0 0 auto;
        }
        .name{
          font-size: clamp(18px, 2.6vw, 30px);
          font-weight: 1000;
          letter-spacing: -0.2px;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
          max-width: 100%;
        }

        .arrow{
          font-size: 26px;
          font-weight: 900;
          opacity: .72;
          transform: translateY(-1px);
        }

        .actions{
          margin-top: 6px;
          display:flex;
          gap: 10px;
          flex-wrap: wrap;
          justify-content: center;
        }
        .hint{
          margin-top: 6px;
          font-weight: 850;
          opacity: .82;
        }

        /* Topic-Mechanik B */
        .answerInputBox{
          margin-top: 8px;
          width: min(680px, 92vw);
          display: flex;
          gap: 10px;
          flex-direction: column;
        }
        .answerInputRow{
          display: flex;
          gap: 8px;
          align-items: stretch;
        }
        .answerInput{
          flex: 1;
          font-size: clamp(18px, 2.4vw, 24px);
          font-weight: 800;
          padding: 14px 18px;
          border-radius: 16px;
          background: rgba(0,0,0,0.32);
          border: 2px solid rgba(255,255,255,0.18);
          color: white;
          text-align: center;
        }
        .answerInput:focus{
          outline: 3px solid rgba(255,214,10,0.7);
          border-color: rgba(255,214,10,0.9);
        }
        .voiceInputBtn{
          flex-shrink: 0;
          width: 52px;
          font-size: 20px;
          border-radius: 16px;
          background: rgba(0,0,0,0.32);
          border: 2px solid rgba(255,255,255,0.18);
          cursor: pointer;
          transition: transform .15s ease, background .2s ease, border-color .2s ease;
        }
        .voiceInputBtn:hover{
          background: rgba(0,0,0,0.45);
        }
        .voiceInputBtn:active{
          transform: scale(0.94);
        }
        .voiceInputBtn:disabled{
          opacity: 0.5;
          cursor: not-allowed;
        }
        .voiceInputBtnActive{
          border-color: rgba(255,60,60,0.9);
          background: rgba(255,60,60,0.22);
          animation: voicePulse 1.1s ease-in-out infinite;
        }
        @keyframes voicePulse{
          0%, 100% { box-shadow: 0 0 0 0 rgba(255,60,60,0.5); }
          50% { box-shadow: 0 0 0 8px rgba(255,60,60,0); }
        }
        .songRoundHint{
          width: min(680px, 92vw);
          margin: 6px auto 0;
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 8px;
          padding: 8px 14px;
          border-radius: 12px;
          background: rgba(255,255,255,0.08);
          font-weight: 700;
          opacity: 0.92;
        }
        .songRoundIcon{
          animation: voicePulse 1.6s ease-in-out infinite;
        }
        .answerStatus,
        .answerVote{
          margin-top: 6px;
          width: min(680px, 92vw);
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 10px;
        }
        .answerStatusLabel{
          font-weight: 850;
          opacity: .8;
          font-size: 14px;
          letter-spacing: 0.5px;
          text-transform: uppercase;
        }
        .answerStatusValue{
          font-size: clamp(22px, 3vw, 36px);
          font-weight: 950;
          text-shadow: 0 8px 28px rgba(0,0,0,0.36);
        }
        .voteCounters{
          display: flex;
          gap: 14px;
          font-weight: 950;
          font-size: 15px;
        }
        .voteCounter{
          padding: 6px 14px;
          border-radius: 999px;
          background: rgba(0,0,0,0.32);
          border: 1px solid rgba(255,255,255,0.14);
        }
        .voteCounter.accept{ color: #34c759; }
        .voteCounter.reject{ color: #ff453a; }

        .usedAnswers{
          margin-top: 10px;
          display: flex;
          flex-wrap: wrap;
          justify-content: center;
          gap: 6px;
          opacity: .78;
        }
        .usedAnswersLabel{
          font-size: 12px;
          font-weight: 800;
          letter-spacing: 0.5px;
          text-transform: uppercase;
          margin-right: 4px;
          align-self: center;
        }
        .usedAnswerChip{
          font-size: 12px;
          font-weight: 800;
          padding: 4px 10px;
          border-radius: 999px;
          background: rgba(255,255,255,0.10);
          border: 1px solid rgba(255,255,255,0.14);
        }
        .usedAnswerChip.more{
          opacity: .7;
        }

        .turnOverlay{
          position: fixed;
          left: 50%;
          top: 22px;
          transform: translateX(-50%);
          z-index: 9999;
          padding: 12px 16px;
          border-radius: 999px;
          background: rgba(0,0,0,0.62);
          border: 1px solid rgba(255,255,255,0.14);
          font-weight: 950;
          letter-spacing: 0.3px;
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
        }
        .topRight{
          position: fixed;
          top: 18px;
          right: 18px;
          z-index: 60;
          display: flex;
          align-items: center;
          gap: 8px;
        }
        .heatPill{
          padding: 8px 14px;
          border-radius: 999px;
          font-weight: 950;
          font-size: 13px;
          letter-spacing: 0.3px;
          border: 1px solid rgba(255,255,255,0.16);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
          user-select: none;
        }
        .modePill{
          display: flex;
          align-items: center;
          gap: 6px;
          padding: 8px 14px;
          border-radius: 999px;
          font-weight: 950;
          font-size: 13px;
          letter-spacing: 0.3px;
          background: rgba(0,0,0,0.26);
          border: 1px solid rgba(255,255,255,0.16);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
          user-select: none;
        }
        .modeArrow{
          display: inline-block;
          transition: transform 260ms cubic-bezier(.2,1,.2,1);
        }
        .heatPill.heat-high{
          animation: heatBlink 0.9s ease-in-out infinite;
        }
        @media (prefers-reduced-motion: reduce){
          .heatPill.heat-high{ animation: none; }
        }
        @keyframes heatBlink{
          0%,100% { filter: brightness(1.0); }
          50%     { filter: brightness(1.32); }
        }

        .selfFlash{
          position: fixed;
          inset: 0;
          z-index: 9997;
          pointer-events: none;
          background: radial-gradient(circle at 50% 45%, rgba(255,69,58,0.0) 0%, rgba(255,69,58,0.45) 65%, rgba(143,15,15,0.62) 100%);
          animation: selfFlashIn 700ms ease-out both;
        }
        @keyframes selfFlashIn{
          0%   { opacity: 0; }
          18%  { opacity: 1; }
          100% { opacity: 0; }
        }
        .kumpirSelfShake{ animation: kumpirShake 700ms cubic-bezier(.36,.07,.19,.97) both; }
        @keyframes kumpirShake{
          0%,100%{ transform: translateX(0); }
          15%    { transform: translateX(-7px); }
          30%    { transform: translateX(7px); }
          45%    { transform: translateX(-5px); }
          60%    { transform: translateX(5px); }
          75%    { transform: translateX(-3px); }
          90%    { transform: translateX(3px); }
        }
        @media (prefers-reduced-motion: reduce){
          .selfFlash{ animation: none; opacity: 0.35; }
          .kumpirSelfShake{ animation: none; }
        }

        .btn{
          appearance:none;
          border: 1px solid rgba(255,255,255,0.14);
          background: rgba(0,0,0,0.22);
          color: white;
          border-radius: 999px;
          padding: 12px 18px;
          font-weight: 950;
          cursor: pointer;
          transition: transform .14s ease, filter .14s ease, border-color .14s ease;
          box-shadow: inset 0 1px 0 rgba(255,255,255,0.10);
        }
        .btn:hover{ transform: translateY(-1px); filter: brightness(1.06); border-color: rgba(255,255,255,0.22); }
        .btn:active{ transform: translateY(0px) scale(0.99); }
        .btn:disabled{ opacity: .65; cursor:not-allowed; transform:none; filter:none; }
        .btnPrimary{ background: linear-gradient(180deg, rgba(11,10,138,0.95), rgba(4,4,94,0.95)); }

        @media (max-width: 520px){
          .strip{ grid-template-columns: 1fr; gap: 10px; border-radius: 28px; }
          .arrow{ display:none; }
          .now,.next{ justify-content: center; }
        }
      `}</style>
        </main>
    );
}
