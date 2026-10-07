"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { serverNow, syncServerClock } from "@/lib/serverClock";

import { PlayerRing } from "@/components/game/PlayerRing";
import { SongRound } from "@/components/game/SongRound";
import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";
import { useLobbyRealtime } from "@/hooks/useLobbyRealtime";
import { useHeartbeat } from "@/hooks/useHeartbeat";
import { usePassAttempt } from "@/hooks/usePassAttempt";
import { useNewAchievements } from "@/hooks/useNewAchievements";
import { useAuth } from "@/components/AuthProvider";
import { AchievementToastPortal } from "@/components/AchievementToastPortal";
import { BackdropFx } from "@/components/game/BackdropFx";
import { MUSIC_PLAYLISTS, playlistLook } from "@/lib/musicGenres";
import type { CSSProperties } from "react";
import { useToastStack } from "@/hooks/useToastStack";
import { ToastStack } from "@/components/ToastStack";
import { LobbyNotFound, isNotFoundError } from "@/components/LobbyNotFound";
import { Spinner } from "@/components/Spinner";
import { Confetti } from "@/components/Confetti";
import { AudioControl } from "@/components/AudioControl";
import { playFx } from "@/lib/gameFx";
import { SeriesTable, type SeriesRow } from "@/components/game/SeriesTable";
import { useI18n } from "@/lib/i18n";
import { track } from "@/lib/track";
import { FinishScreen, type FinishHighlight } from "@/components/game/FinishScreen";

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
    /** Host hat die Lobby gesperrt oder ein Match läuft (Beitritt nicht möglich). */
    locked: boolean;
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
    topic_c: string | null;
    topic_vote_cards: number;
    topic_selected: string | null;
    topic_vote_ends_at: string | null;

    // Countdown (synced)
    countdown_ends_at: string | null;
    countdown_started_at: string | null;
    countdown_starter_player_id: string | null;

    // Tie visualization
    topic_tie_choices: number[] | null;
    topic_tie_pick: number | null;

    // Topic-Mechanik B: Antwort-Validierung
    current_attempt_id: string | null;
    used_answers: string[];

    // Modus-Anzeige
    game_mode: string | null;
    pass_direction: number | null;

    // Serie (mehrere Durchgänge) + Arena-Extras
    series_total: number;
    series_index: number;
    current_song_difficulty: number;
    revenge_nonce: number;
    last_revenge_by: string | null;

    // Song-Raten (Musik-Modus): aktueller, versteckter Song für den Halter
    current_song_id: string | null;
    // Server-Zeitstempel, seit wann current_song_id läuft -- Basis für
    // synchrone Wiedergabe (jeder Client rechnet dieselbe Zielposition aus).
    current_song_started_at: string | null;
    // "title" (Standard, Songtitel erraten) oder "artist" (Interpret nennen)
    song_answer_mode: string | null;

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
    slowest_pass_ms?: number | null;
    total_hold_ms?: number;
    survival_streak?: number;
    eliminated_at_round?: number | null;
    song_points?: number;
    skips_left?: number;
    combo?: number;
    revenge_used?: boolean;
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

// Server-Uhr statt Geräte-Uhr (lib/serverClock.ts)
function msUntil(ts: string | null): number | null {
    if (!ts) return null;
    const ms = Date.parse(ts);
    if (Number.isNaN(ms)) return null;
    return ms - serverNow();
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

function GamePageInner({ onSpectator }: { onSpectator: (v: boolean) => void }) {
    const { t } = useI18n();
    const supabase = getSupabaseClient();
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId } = usePlayerIdentity();
    const { user } = useAuth();

    // Beim Laden kalibrieren und danach jede Minute nachziehen (Uhren driften).
    useEffect(() => {
        void syncServerClock(supabase);
        const t = window.setInterval(() => void syncServerClock(supabase), 60000);
        return () => window.clearInterval(t);
    }, [supabase]);

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
    const [explodeMsLeft, setExplodeMsLeft] = useState<number | null>(null);

    // Prevent spamming finalize/advance
    const finalizeInFlightRef = useRef(false);
    const advanceInFlightRef = useRef(false);

    // Pass UX
    const { toasts, pushToast } = useToastStack({ maxVisible: 3 });
    const [passBusy, setPassBusy] = useState(false);

    // Topic-Mechanik B: Antwort-Eingabe + Validierung
    const [answerDraft, setAnswerDraft] = useState("");
    const [answerWrong, setAnswerWrong] = useState(false);
    const [kickBusyId, setKickBusyId] = useState<string | null>(null);

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

    // Großes, kurz eingeblendetes "Nur noch X Spieler übrig!" bei jeder
    // Elimination -- verschwindet von selbst wieder.
    // Ausscheide-Pop-up: erst "X ist raus", danach (nach dem Ausblenden) "Nur noch N übrig".
    const [elimPopup, setElimPopup] = useState<{ key: number; text: string; kind: "out" | "left" } | null>(null);
    const elimTimersRef = useRef<number[]>([]);
    const [kickOpen, setKickOpen] = useState(false);
    const answerInputRef = useRef<HTMLInputElement | null>(null);
    const elimKeyRef = useRef(0);

    // HUD swap animation trigger
    const [hudPulseNonce, setHudPulseNonce] = useState(0);

    const inFlightRef = useRef(false);
    // Live-Änderungen (Realtime) laden SOFORT neu, statt auf die nächste 4s-Abfrage zu warten
    // (sonst kam z. B. ein neuer Song 4-5 s zu spät bei allen an). Läuft gerade eine Abfrage,
    // wird direkt danach noch einmal geladen; mehrere Ereignisse auf einmal ergeben so höchstens
    // zwei Abfragen.
    const loadNowRef = useRef<(() => void) | null>(null);
    const reloadPendingRef = useRef(false);
    const inFlightSinceRef = useRef(0);
    const prevHolderRef = useRef<string | null>(null);
    const passNonceRef = useRef(0);
    const prevAliveRef = useRef<Set<string>>(new Set());
    const prevPhaseRef = useRef<LobbyPhase | null>(null);
    const lastTickSecondRef = useRef<number>(-1);

    // Für die kontinuierliche Heat-Anzeige: wie viel Zeit hatte DIESE
    // Halter-Runde ursprünglich (statt nur "wie viel ist noch übrig")?
    // Wird bei jedem Halterwechsel aus dem frischen explode_at neu gesetzt.
    const roundTotalMsRef = useRef<number>(15000);
    const lastExplodeMsRef = useRef<number | null>(null);
    const lastFuseRoundRef = useRef<number>(-1);

    // Rematch / reset busy
    const [endActionBusy, setEndActionBusy] = useState<null | "rematch" | "reset">(null);

    // Bug "Rematch -> beim nächsten Endscreen steht ewig 'Starte…'": nach einem
    // ERFOLGREICHEN Rematch/Reset wurde der Busy-Zustand nie zurückgesetzt
    // (nur im Fehlerfall). Sobald das Match nicht mehr 'finished' ist, wieder frei.
    useEffect(() => {
        if (lobby?.phase !== "finished") setEndActionBusy(null);
    }, [lobby?.phase]);

    // rematch_wait: Bereit-Toggle + Auto-Start sobald alle bereit sind
    const startRematchInFlightRef = useRef(false);

    // post-round feedback
    const lastLoserRef = useRef<string | null>(null);

    // Finished screen UI

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

    // Zuschauer: Lobby geladen, Spielerliste da, aber man ist nicht Teil davon (spät dazugekommen).
    const isSpectator = !!lobby && players.length > 0 && !meRow;
    useEffect(() => {
        onSpectator(isSpectator);
    }, [isSpectator, onSpectator]);

    // Anonyme Auswertung "Weg der Spieler": einmal pro Wechsel in die Endphase (nicht beim Neuladen).
    const trackedPhaseRef = useRef<string | null>(null);
    useEffect(() => {
        const phase = lobby?.phase ?? null;
        const prev = trackedPhaseRef.current;
        trackedPhaseRef.current = phase;
        if (phase === "finished" && prev && prev !== "finished") {
            track("game_finished", {
                solo: players.filter((p) => !p.is_bot).length < 2,
                spectator: isSpectator,
                rounds: lobby?.series_total ?? 1,
            });
        }
    }, [lobby?.phase, lobby?.series_total, players, isSpectator]);

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

    // Verbindung wirkt verloren: last_seen_at (Heartbeat alle ~8s) ist älter
    // als 20s. Reines UI-Signal, ändert keine Server-Logik/Elimination.
    const disconnectedIds = useMemo(() => {
        const STALE_MS = 20000;
        const now = Date.now();
        const set = new Set<string>();
        for (const p of players) {
            // Bots haben keinen Browser und damit keinen Heartbeat -- sie
            // sind nie "getrennt".
            if (p.is_bot || !p.is_alive || !p.last_seen_at) continue;
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

    // ARENA-WERTUNG:
    //  - Platzierung = Überlebensreihenfolge (Sieger = letzter Lebender, dann
    //    wer in der späteren Runde ausgeschieden ist; Gleichstand -> mehr
    //    Song-Punkte, dann mehr Pässe). Das ist die einzige Rangfolge.
    //  - Arena-Punkte (Spalte "Punkte") sind davon getrennt und fließen später
    //    in Bestenlisten ein: Platzierung (1. = 100 ... Letzter = 0, linear)
    //    + Song-Punkte x 15 (Titel 15, Interpret 7.5) + Clutch-Pässe x 10.
    const ranking = useMemo(() => {
        const base = players.map((p) => {
            const pass = p.pass_count ?? 0;
            const clutch = p.clutch_pass_count ?? 0;
            const streak = p.survival_streak ?? 0;
            const fastest = p.fastest_pass_ms ?? null;
            const slowest = p.slowest_pass_ms ?? null;
            const songPoints = p.song_points ?? 0;

            // "Runden überlebt": Sieger (nie eliminiert) haben alle Runden des
            // Matches überlebt, alle anderen bis zu der Runde, in der sie
            // ausgeschieden sind (Timer-Explosion oder Host-Kick, Migration 048).
            const roundsSurvived = p.eliminated_at_round ?? lobby?.round_number ?? 0;
            const survivalKey = p.is_alive ? Number.POSITIVE_INFINITY : (p.eliminated_at_round ?? 0);

            return { ...p, pass, clutch, streak, fastest, slowest, songPoints, roundsSurvived, survivalKey, holdMs: p.total_hold_ms ?? 0 };
        });

        base.sort((a, b) => b.survivalKey - a.survivalKey || b.songPoints - a.songPoints || b.pass - a.pass);

        const n = base.length;
        return base.map((r, i) => {
            const placementPts = n > 1 ? Math.round((100 * (n - 1 - i)) / (n - 1)) : 100;
            const score = placementPts + Math.round(r.songPoints * 15) + r.clutch * 10;
            return { ...r, place: i + 1, score };
        });
    }, [players, lobby?.round_number]);

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
            const { data, error } = await supabase.rpc("rpc_attempt_pass", {
                p_code: codeUpper,
                p_player_id: playerId,
                p_answer: answer,
            });
            // data === null bei erfolgreichem Aufruf = Song-Antwort abgelehnt
            // (falsch), ohne Fehler -- so kann der Server die 1s-Sperre nach
            // einem Fehlversuch speichern, ohne dass ein RAISE sie zurückrollt.
            if (!error && data == null) return { message: "answer_incorrect" };
            return error;
        },
        [supabase]
    );

    // Host-Live-Kick: sofortige Eliminierung während der laufenden Runde,
    // ohne Bestätigung. Antworten werden ab jetzt immer angenommen --
    // das hier ist der manuelle Ausgleich dafür.
    const rpcHostKickDuringRound = useCallback(
        async (codeUpper: string, hostPlayerId: string, targetPlayerId: string) => {
            const { error } = await supabase.rpc("rpc_host_kick_during_round", {
                p_code: codeUpper,
                p_host_player_id: hostPlayerId,
                p_target_player_id: targetPlayerId,
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
        // Hängt eine Abfrage schon ungewöhnlich lange, nicht auf sie warten.
        if (inFlightRef.current && Date.now() - inFlightSinceRef.current < 8000) {
            reloadPendingRef.current = true;
            return;
        }
        inFlightRef.current = false;
        loadNowRef.current?.();
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

    const isHost = !!mePlayerId && lobby?.host_player_id === mePlayerId;
    // Bots laufen serverseitig (pg_cron, Migration 064/070) -- kein Client-Bot-Motor mehr.

    // -----------------------------
    // Poll loop (fallback when realtime is offline)
    // -----------------------------
    useEffect(() => {
        let alive = true;

        const load = async () => {
            if (inFlightRef.current) return;
            inFlightRef.current = true;
            inFlightSinceRef.current = Date.now();

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
                    locked: raw.locked === true,
                    host_player_id: (raw.host_player_id as string | null) ?? null,
                    holder_player_id: (raw.holder_player_id as string | null) ?? null,

                    explode_at: (raw.explode_at as string | null) ?? null,

                    last_activity_at: (raw.last_activity_at as string | null) ?? null,
                    run_started_at: (raw.run_started_at as string | null) ?? null,

                    round_number: (raw.round_number as number | null) ?? null,
                    last_loser_player_id: (raw.last_loser_player_id as string | null) ?? null,

                    topic_a: (raw.topic_a as string | null) ?? null,
                    topic_b: (raw.topic_b as string | null) ?? null,
                    topic_c: (raw.topic_c as string | null) ?? null,
                    topic_vote_cards: (raw.topic_vote_cards as number | null) ?? 3,
                    topic_selected: (raw.topic_selected as string | null) ?? null,
                    topic_vote_ends_at: (raw.topic_vote_ends_at as string | null) ?? null,

                    countdown_started_at: (raw.countdown_started_at as string | null) ?? null,
                    countdown_ends_at: (raw.countdown_ends_at as string | null) ?? null,
                    countdown_starter_player_id: (raw.countdown_starter_player_id as string | null) ?? null,

                    topic_tie_choices: (raw.topic_tie_choices as number[] | null) ?? null,
                    topic_tie_pick: (raw.topic_tie_pick as number | null) ?? null,

                    current_attempt_id: (raw.current_attempt_id as string | null) ?? null,
                    used_answers: (raw.used_answers as string[] | null) ?? [],

                    game_mode: (raw.game_mode as string | null) ?? "original",
                    pass_direction: (raw.pass_direction as number | null) ?? 1,
                    series_total: (raw.series_total as number | null) ?? 1,
                    series_index: (raw.series_index as number | null) ?? 1,
                    current_song_difficulty: (raw.current_song_difficulty as number | null) ?? 2,
                    revenge_nonce: (raw.revenge_nonce as number | null) ?? 0,
                    last_revenge_by: (raw.last_revenge_by as string | null) ?? null,

                    current_song_id: (raw.current_song_id as string | null) ?? null,
                    current_song_started_at: (raw.current_song_started_at as string | null) ?? null,
                    song_answer_mode: (raw.song_answer_mode as string | null) ?? null,

                    answer_mode: (raw.answer_mode as string | null) ?? "text",
                };

                // Letzten Verlierer merken (einmalig)
                if (nextLobby.last_loser_player_id && nextLobby.last_loser_player_id !== lastLoserRef.current) {
                    // (Die Anzeige "X ist raus" macht das Ausscheide-Pop-up.)
                    lastLoserRef.current = nextLobby.last_loser_player_id;
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

                // “Your turn” overlay
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
                            "slowest_pass_ms",
                            "total_hold_ms",
                            "survival_streak",
                            "eliminated_at_round",
                            "song_points",
                            "skips_left",
                            "combo",
                            "revenge_used",
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
                    const due = !Number.isNaN(explodeMs) && serverNow() >= explodeMs - 150;
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
                if (reloadPendingRef.current && alive) {
                    reloadPendingRef.current = false;
                    void load();
                }
            }
        };

        loadNowRef.current = () => void load();
        void load();
        // When realtime is "live": slow polling (4s safety net).
        // When offline/connecting: tight polling (650ms).
        const effectiveMs = realtimeStatus === "live" ? 4000 : 650;
        const t = window.setInterval(() => void load(), effectiveMs);

        return () => {
            alive = false;
            loadNowRef.current = null;
            window.clearInterval(t);
        };
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
                if (!Number.isNaN(explodeMs) && serverNow() >= explodeMs - 150) {
                    void rpcTickGame(code);
                }
            } else if (lobby.phase === "rematch_wait" && lobby.countdown_ends_at) {
                // Rematch startet jetzt zeitgesteuert (10s ab dem ersten "R")
                // statt erst wenn ALLE nochmal manuell auf Bereit klicken.
                const dueMs = msUntil(lobby.countdown_ends_at);
                if (dueMs !== null && dueMs <= 0 && !startRematchInFlightRef.current) {
                    startRematchInFlightRef.current = true;
                    void (async () => {
                        try {
                            const { error } = await supabase.rpc("rpc_start_rematch_if_ready", { p_code: code });
                            if (error) showToast(`❌ ${error.message}`, 2400);
                        } finally {
                            startRematchInFlightRef.current = false;
                        }
                    })();
                }
            } else if (lobby.phase === "set_summary" && lobby.countdown_ends_at) {
                const dueMs = msUntil(lobby.countdown_ends_at);
                if (dueMs !== null && dueMs <= 0 && !startRematchInFlightRef.current) {
                    startRematchInFlightRef.current = true;
                    void (async () => {
                        try {
                            await supabase.rpc("rpc_start_next_set", { p_code: code });
                        } finally {
                            startRematchInFlightRef.current = false;
                        }
                    })();
                }
            }
        }, 250);
        return () => window.clearInterval(t);
    }, [lobby, code, rpcFinalizeTopicVote, rpcAdvanceFromCountdown, rpcTickGame, supabase, showToast]);

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
            const died = [...prevAlive].filter((id) => !currentAlive.has(id));
            let anyDied = false;
            for (const id of prevAlive) {
                if (!currentAlive.has(id)) {
                    anyDied = true;
                    setExplodedPlayerId(id);
                    const isMe = !!mePlayerId && id === mePlayerId;
                    playFx(isMe ? "selfExplode" : "explode");
                    if (isMe) {
                        setSelfShake(true);
                        window.setTimeout(() => setSelfShake(false), 700);
                    }
                    window.setTimeout(() => setExplodedPlayerId((cur) => (cur === id ? null : cur)), 900);
                    break; // FX/Shake nur einmal pro Tick -- bei mehreren gleichzeitig
                    // erkannten Toden (z.B. Tab war kurz im Hintergrund, mehrere
                    // Runden liefen durch) reicht ein Explosions-Sound.
                }
            }
            // Das große "Nur noch X übrig"-Banner ist unabhängig vom Spielmodus
            // (Original/Teleport/Reverse) und feuert bei JEDEM erkannten
            // Rückgang der Spielerzahl -- auch wenn zwischen zwei Polls mehr als
            // eine Elimination passiert ist, zeigt es immer den aktuell
            // korrekten Stand.
            if (anyDied) {
                const nameOf = (id: string) => players.find((p) => p.player_id === id)?.name ?? "Jemand";
                const diedNames = died.map((id) => (id === mePlayerId ? "Du" : nameOf(id)));
                const outText =
                    diedNames.length === 1
                        ? `${diedNames[0]} ${diedNames[0] === "Du" ? "bist" : "ist"} raus`
                        : `${diedNames.slice(0, -1).join(", ")} und ${diedNames[diedNames.length - 1]} sind raus`;
                const aliveNames = players
                    .filter((p) => currentAlive.has(p.player_id))
                    .sort((x, y) => (x.player_id === mePlayerId ? -1 : 0) - (y.player_id === mePlayerId ? -1 : 0))
                    .map((p) => (p.player_id === mePlayerId ? "du" : p.name));
                const leftText =
                    aliveNames.length >= 3
                        ? `Nur noch ${aliveNames.length} übrig`
                        : aliveNames.length === 2
                          ? `Nur noch ${aliveNames[0]} und ${aliveNames[1]} übrig`
                          : null;
                elimTimersRef.current.forEach((t) => window.clearTimeout(t));
                elimTimersRef.current = [];
                setElimPopup({ key: ++elimKeyRef.current, text: outText, kind: "out" });
                elimTimersRef.current.push(
                    window.setTimeout(() => setElimPopup(leftText ? { key: ++elimKeyRef.current, text: leftText, kind: "left" } : null), 2000),
                    window.setTimeout(() => setElimPopup(null), 4000)
                );
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

    // Synced timers. requestAnimationFrame pausiert komplett, sobald der Tab
    // in den Hintergrund geht (Screen-Lock, App-Wechsel, Benachrichtigung) --
    // genau das erzeugte den gemeldeten Bug ("bei mir stand die Zahl fest bei
    // 10, beim anderen Gerät lief sie normal runter"): rAF pausierte auf dem
    // einen Gerät, lief auf dem anderen normal weiter, beide hatten aber
    // dieselben Server-Zeitstempel. Der explizite visibilitychange-Handler
    // erzwingt sofort einen frischen step(), sobald der Tab wieder sichtbar
    // wird, statt auf den nächsten (evtl. erst Sekunden später kommenden)
    // Frame zu warten.
    useEffect(() => {
        let raf = 0;

        const step = () => {
            if (!lobby) {
                setVoteSecondsLeft(null);
                setCountdownSecondsLeft(null);
                setExplodeMsLeft(null);
                raf = window.requestAnimationFrame(step);
                return;
            }

            if (lobby.phase === "topic_vote") {
                const ms = msUntil(lobby.topic_vote_ends_at);
                setVoteSecondsLeft(ms === null ? null : clamp(Math.ceil(ms / 1000), 0, 99));
            } else setVoteSecondsLeft(null);

            if (lobby.phase === "countdown" || lobby.phase === "rematch_wait" || lobby.phase === "set_summary") {
                const ms = msUntil(lobby.countdown_ends_at);
                setCountdownSecondsLeft(ms === null ? null : clamp(Math.ceil(ms / 1000), 0, 12));
            } else setCountdownSecondsLeft(null);

            if (lobby.phase === "running") {
                setExplodeMsLeft(msUntil(lobby.explode_at));
            } else setExplodeMsLeft(null);

            raf = window.requestAnimationFrame(step);
        };

        const onVisible = () => {
            if (document.visibilityState !== "visible") return;
            if (raf) window.cancelAnimationFrame(raf);
            step();
        };
        document.addEventListener("visibilitychange", onVisible);

        raf = window.requestAnimationFrame(step);
        return () => {
            if (raf) window.cancelAnimationFrame(raf);
            document.removeEventListener("visibilitychange", onVisible);
        };
    }, [lobby]);

    // Zündschnur-Länge der aktuellen Runde: startet mit der Restzeit beim
    // Rundenbeginn (neue Runde = neue Schnur) und wächst um jede Bonuszeit
    // (Pass-Bonus) -- so springt der Ring nach einem guten Pass sichtbar
    // zurück, und ein Song-Tausch (verkürzt die Schnur) lässt ihn vorrücken.
    useEffect(() => {
        if (!lobby || lobby.phase !== "running" || !lobby.explode_at) {
            lastExplodeMsRef.current = null;
            return;
        }
        const exp = Date.parse(lobby.explode_at);
        if (Number.isNaN(exp)) return;
        const round = lobby.round_number ?? 0;
        if (lastExplodeMsRef.current == null || round !== lastFuseRoundRef.current) {
            const ms = msUntil(lobby.explode_at);
            roundTotalMsRef.current = Math.max(1500, ms ?? 15000);
        } else if (exp > lastExplodeMsRef.current) {
            roundTotalMsRef.current += exp - lastExplodeMsRef.current;
        }
        lastExplodeMsRef.current = exp;
        lastFuseRoundRef.current = round;
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [lobby?.explode_at, lobby?.round_number, lobby?.phase]);

    // Vote action (optimistic local state so highlight is instant)
    const vote = useCallback(
        async (choice: 1 | 2 | 3) => {
            if (!mePlayerId) return showToast("⚠️ Keine Player-ID", 1800);
            if (isSpectator) return;
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
        [mePlayerId, isSpectator, lobby, voteBusy, myVote, supabase, showToast]
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
        // Im Song-Modus gibt es keine Duplikat-Sperre (jeder Song wird einzeln
        // geprüft, derselbe Interpret darf bei mehreren Songs zählen).
        if (!lobby.current_song_id && used.includes(clean.toLowerCase())) {
            return showToast("⚠️ Schon gesagt — andere Antwort probieren", 2000);
        }

        setPassBusy(true);
        try {
            const err = await rpcAttemptPass(code, mePlayerId, clean);
            if (err) {
                if (err.message?.includes("answer_incorrect")) {
                    // Falsche Song-Antwort: kurzes rotes Aufblitzen + Fehler-Sound
                    // statt einer Toast-Fehlermeldung -- der Halter darf sofort
                    // nochmal tippen, die Runde läuft normal weiter.
                    setAnswerWrong(false);
                    window.requestAnimationFrame(() => {
                        setAnswerWrong(true);
                        answerInputRef.current?.select();
                        window.setTimeout(() => setAnswerWrong(false), 1800);
                    });
                    playFx("wrong");
                    return;
                }
                if (err.message?.includes("too_fast")) return showToast("⏳ Kurz warten …", 900);
                if (err.message?.includes("time_up")) return showToast("⏰ Zu spät", 1400);
                return showToast(`❌ ${err.message}`, 2400);
            }
            setAnswerDraft("");
            showToast("✅ Angenommen", 900);
        } catch (e: unknown) {
            showToast(`❌ ${getErrorMessage(e)}`, 2400);
        } finally {
            setPassBusy(false);
        }
    }, [mePlayerId, lobby, iAmEliminated, isMeHolder, passBusy, code, answerDraft, rpcAttemptPass, showToast]);

    // Eingabefeld sofort fokussieren, sobald man dran ist (und nach einer falschen Antwort).
    useEffect(() => {
        if (isMeHolder && lobby?.phase === "running") answerInputRef.current?.focus();
    }, [isMeHolder, lobby?.phase, lobby?.current_song_id, answerWrong]);

    // Host-Live-Kick: ein Klick auf einen Namen eliminiert sofort, ohne
    // Bestätigung -- Ausgleich dafür, dass Antworten jetzt immer akzeptiert
    // werden und die Spieler sozial entscheiden, wer eigentlich raus muss.
    const handleHostKick = useCallback(
        async (targetPlayerId: string) => {
            if (!mePlayerId || !lobby) return;
            if (lobby.host_player_id !== mePlayerId) return;
            if (kickBusyId) return;

            setKickBusyId(targetPlayerId);
            try {
                const err = await rpcHostKickDuringRound(code, mePlayerId, targetPlayerId);
                if (err) return showToast(`❌ ${err.message}`, 2400);
            } catch (e: unknown) {
                showToast(`❌ ${getErrorMessage(e)}`, 2400);
            } finally {
                setKickBusyId(null);
            }
        },
        [mePlayerId, lobby, kickBusyId, code, rpcHostKickDuringRound, showToast]
    );

    // Ergebnisse der Serie (nur bei mehreren Durchgängen): für Zwischenstand
    // und Gesamtwertung am Ende.
    const [seriesRows, setSeriesRows] = useState<SeriesRow[]>([]);
    useEffect(() => {
        if (!lobby || (lobby.phase !== "set_summary" && lobby.phase !== "finished")) return;
        if ((lobby.series_total ?? 1) <= 1) return;
        let cancel = false;
        void (async () => {
            const { data } = await supabase
                .from("series_results")
                .select("set_index,player_id,name,place,arena_points,song_points,is_bot")
                .eq("lobby_id", lobby.id)
                .order("set_index", { ascending: true });
            if (!cancel && data) setSeriesRows(data as unknown as SeriesRow[]);
        })();
        return () => {
            cancel = true;
        };
    }, [lobby?.id, lobby?.phase, lobby?.series_index, lobby?.series_total, supabase]); // eslint-disable-line react-hooks/exhaustive-deps

    // Serien-Sieger (Summe der Arena-Punkte, Gleichstand: besserer Ø-Platz)
    const seriesRanked = useMemo(() => {
        const m = new Map<string, { id: string; name: string; total: number; placeSum: number; n: number; wins: number }>();
        for (const r of seriesRows) {
            const e = m.get(r.player_id) ?? { id: r.player_id, name: r.name, total: 0, placeSum: 0, n: 0, wins: 0 };
            if (r.place === 1) e.wins += 1;
            e.total += r.arena_points;
            e.placeSum += r.place;
            e.n += 1;
            m.set(r.player_id, e);
        }
        return [...m.values()].sort((a, b) => b.total - a.total || b.wins - a.wins || a.placeSum / a.n - b.placeSum / b.n);
    }, [seriesRows]);
    const seriesLeader = seriesRanked[0] ?? null;
    const mySeriesRank = seriesRanked.findIndex((e) => e.id === mePlayerId) + 1;

    // Combo-Hinweis für mich
    const prevComboRef = useRef(0);
    useEffect(() => {
        const c = meRow?.combo ?? 0;
        if (c >= 2 && c > prevComboRef.current) {
            showToast(`🔥 Combo ×${c} (+${Math.min(2, 0.5 * (c - 1))}s)`, 1500);
        }
        prevComboRef.current = c;
    }, [meRow?.combo, showToast]);

    // Rache-Pass: Ausgeschiedene drehen einmal die Richtung
    const [revengeBusy, setRevengeBusy] = useState(false);
    const handleRevenge = useCallback(async () => {
        if (!mePlayerId || revengeBusy) return;
        setRevengeBusy(true);
        try {
            const { error } = await supabase.rpc("rpc_revenge_flip", { p_code: code, p_player_id: mePlayerId });
            if (error) {
                if (error.message.includes("duel_no_revenge")) showToast("Im Duell gibt es keine Rache mehr", 1800);
                else showToast("Rache-Pass nicht möglich", 1600);
            }
        } finally {
            setRevengeBusy(false);
        }
    }, [mePlayerId, revengeBusy, supabase, code, showToast]);

    const prevRevengeNonceRef = useRef<number | null>(null);
    useEffect(() => {
        const n = lobby?.revenge_nonce ?? 0;
        if (prevRevengeNonceRef.current !== null && n > prevRevengeNonceRef.current) {
            const who = players.find((p) => p.player_id === lobby?.last_revenge_by)?.name ?? "Jemand";
            showToast(`🔄 ${who} dreht die Richtung!`, 2400);
            playFx("pass");
        }
        prevRevengeNonceRef.current = n;
    }, [lobby?.revenge_nonce]); // eslint-disable-line react-hooks/exhaustive-deps

    // Song-Tausch-Joker (1x pro Match, kostet 2s Zündschnur)
    const [skipBusy, setSkipBusy] = useState(false);
    const handleSkipSong = useCallback(async () => {
        if (!mePlayerId || skipBusy) return;
        setSkipBusy(true);
        try {
            const { error } = await supabase.rpc("rpc_skip_song", { p_code: code, p_player_id: mePlayerId });
            if (error) {
                if (error.message.includes("too_late")) showToast("⏳ Zu spät zum Tauschen", 1500);
                else if (error.message.includes("no_skips_left")) showToast("Kein Joker mehr übrig", 1500);
                else showToast(`❌ ${error.message}`, 2200);
            } else {
                showToast("🔀 Neuer Song (−2s)", 1400);
            }
        } finally {
            setSkipBusy(false);
        }
    }, [mePlayerId, skipBusy, supabase, code, showToast]);

    // Rematch handler (also bound to "R" key)
    const handleRematch = useCallback(async () => {
        if (endActionBusy) return;
        if (!mePlayerId || isSpectator) return;
        setEndActionBusy("rematch");
        const { error } = await supabase.rpc("rpc_rematch", { p_code: code, p_player_id: mePlayerId });
        if (error) {
            setEndActionBusy(null);
            showToast(`❌ Rematch: ${error.message}`, 2400);
            return;
        }
        showToast("🔁 Rematch gestartet", 1200);
    }, [endActionBusy, mePlayerId, isSpectator, supabase, code, showToast]);

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

            // Topic vote: 1 / 2 / 3 -- "3" ist immer gültig (echtes Thema C oder Zufällig).
            if (lobby.phase === "topic_vote" && (ev.key === "1" || ev.key === "2" || ev.key === "3") && Number(ev.key) <= (lobby.topic_vote_cards ?? 3) && (lobby.topic_vote_cards ?? 3) > 1) {
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
    if (fatalError && isNotFoundError(fatalError)) return <LobbyNotFound code={code} />;
    if (fatalError) {
        return (
            <main className="fullH" style={{ display: "grid", placeItems: "center", padding: 24 }}>
                <div style={{ width: "min(720px, calc(100vw - 48px))", textAlign: "center" }}>
                    <div style={{ fontWeight: 950, fontSize: 22 }}>⚠️ Spiel konnte nicht geladen werden</div>
                    <div style={{ marginTop: 10, opacity: 0.8 }}>{fatalError}</div>
                </div>
            </main>
        );
    }

    if (!lobby)
        return (
            <main className="fullH" style={{ display: "grid", placeItems: "center", padding: 24, color: "white" }}>
                <Spinner size={28} label="Lade Spiel…" />
            </main>
        );

    // Labels -- dritte Karte ist ein ECHTES drittes Thema, wenn der Pool
    // genug Verschiedenes hergibt (topic_c gesetzt), sonst bleibt sie
    // "Zufällig" wie eh und je (verlost dann zwischen Thema A und B).
    const aLabel = lobby.topic_a ?? "…";
    const bLabel = lobby.topic_b ?? "…";
    const cLabel = lobby.topic_c ?? "Zufall";
    // Anzahl Karten: 1 Playlist = keine Abstimmung, 2 Playlists = nur A und B, ab 3 = A, B und Zufall
    const voteCards = Math.min(3, Math.max(1, lobby.topic_vote_cards ?? 3));
    // Jede Playlist hat ihr Symbol und ihre Akzentfarbe (Karte 3 ohne echtes Thema = Zufall)
    const lookA = playlistLook(aLabel);
    const lookB = playlistLook(bLabel);
    const lookC = lobby.topic_c ? playlistLook(cLabel) : { icon: "🎲", color: "#a78bfa" };
    const plStyle = (color: string) => ({ "--pl": color }) as CSSProperties;

    // =========================================================
    // PHASE: TOPIC VOTE  (NO blinking)
    // =========================================================
    if (lobby.phase === "topic_vote") {
        const timeLeft = voteSecondsLeft ?? 15;
        const duration = 15;
        const progress = clamp(timeLeft / duration, 0, 1);

        return (
            <main
                className="fullH"
                style={{
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    position: "relative",
                    overflow: "hidden",
                    color: "white",
                }}
            >
                <div style={{ width: "min(1160px, calc(100vw - 48px))", position: "relative", zIndex: 2 }}>
                    <div style={{ textAlign: "center" }}>
                        <div className="kicker">Abstimmung</div>

                        <div className="headline">
                            Welche Playlist?
                            <span className="headlineGlow" aria-hidden />
                        </div>

                        <div className="topicGrid">
                            <button
                                type="button"
                                onClick={() => void vote(1)}
                                disabled={voteBusy || !mePlayerId || isSpectator || voteCards === 1}
                                className={`glassCard ${myVote === 1 ? "active" : ""}`}
                                style={plStyle(lookA.color)}
                            >
                                <div className="cardEmoji" aria-hidden>
                                    {lookA.icon}
                                </div>
                                <div className="glassShine" aria-hidden />
                                <div className="cardTop">
                                    <span className="chip">①</span>
                                    <span className="micro">Playlist A</span>
                                </div>
                                <div className="cardTitle">{aLabel}</div>
                                <div className="cardHint">{voteCards === 1 ? "Nur diese Playlist ist aktiv" : myVote === 1 ? "✓ Deine Wahl" : "Tippen zum Wählen"}</div>
                            </button>

                            {voteCards >= 2 ? (
<button
                                type="button"
                                onClick={() => void vote(2)}
                                disabled={voteBusy || !mePlayerId || isSpectator}
                                className={`glassCard ${myVote === 2 ? "active" : ""}`}
                                style={plStyle(lookB.color)}
                            >
                                <div className="cardEmoji" aria-hidden>
                                    {lookB.icon}
                                </div>
                                <div className="glassShine" aria-hidden />
                                <div className="cardTop">
                                    <span className="chip">②</span>
                                    <span className="micro">Playlist B</span>
                                </div>
                                <div className="cardTitle">{bLabel}</div>
                                <div className="cardHint">{myVote === 2 ? "✓ Deine Wahl" : "Tippen zum Wählen"}</div>
                            </button>
                            ) : null}

                            {voteCards >= 3 ? (
<button
                                type="button"
                                onClick={() => void vote(3)}
                                disabled={voteBusy || !mePlayerId || isSpectator}
                                className={`glassCard ${myVote === 3 ? "active" : ""}`}
                                style={plStyle(lookC.color)}
                            >
                                <div className="cardEmoji" aria-hidden>
                                    {lookC.icon}
                                </div>
                                <div className="glassShine" aria-hidden />
                                <div className="cardTop">
                                    <span className="chip">{lobby.topic_c ? "③" : "🎲"}</span>
                                    <span className="micro">{lobby.topic_c ? "Thema C" : "Zufall"}</span>
                                </div>
                                <div className="cardTitle">{cLabel}</div>
                                <div className="cardHint">
                                    {myVote === 3 ? "✓ Deine Wahl" : lobby.topic_c ? "Tippen zum Wählen" : "Das Los zieht eine andere Playlist"}
                                </div>
                            </button>
                            ) : null}
                        </div>

                        <div className="statusLine">
                            {voteCards === 1 ? "Es geht gleich los…" : allVoted ? "✅ Alle haben gewählt – wird ausgewertet…" : "Wählt schnell – bei allen Votes geht’s sofort weiter."}
                        </div>

                        <ToastStack toasts={toasts} inline />
                    </div>
                </div>

                <div className="bottomBar" style={{ zIndex: 50 }}>
                    <div className="bottomInner">
                        <div className="bottomLeft">
                            <div className="brandMark">🥔</div>
                            <div className="bottomText">
                                <div className="bottomTitle">Abstimmung läuft</div>
                                <div className="bottomSub">{myVote ? "Du kannst noch wechseln." : "Tippe auf eine Karte."}</div>
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
          .headline{margin-top:10px;font-family:var(--font-display);font-size:clamp(36px,4.8vw,70px);font-weight:800;letter-spacing:-0.6px;position:relative;display:inline-block;text-shadow:0 24px 80px rgba(0,0,0,0.35);animation:${reduceMotion ? "none" : "heroIn 900ms cubic-bezier(.16,1,.3,1) both"};}
          .headlineGlow{position:absolute;inset:-30px -60px;background:radial-gradient(circle at 40% 35%, rgba(255,214,10,0.25), rgba(255,149,0,0.18), rgba(255,45,85,0.06), transparent 70%);filter:blur(18px);opacity:.9;pointer-events:none;animation:${reduceMotion ? "none" : "glowFloat 4.2s ease-in-out infinite"};}
          .topicGrid{margin-top:24px;display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:18px;}
          .glassCard{color:white;position:relative;width:100%;border-radius:28px;padding:22px 22px 20px;min-height:200px;text-align:left;cursor:pointer;border:2px solid rgba(255,255,255,0.18);background:rgba(38,9,6,0.50);backdrop-filter:blur(16px) saturate(130%);-webkit-backdrop-filter:blur(16px) saturate(130%);box-shadow:0 18px 50px rgba(60,8,0,0.35),inset 0 1px 0 rgba(255,255,255,0.14);overflow:hidden;transition:transform .2s cubic-bezier(.2,1,.2,1), box-shadow .2s ease, border-color .2s ease, background .2s ease;animation:${reduceMotion ? "none" : "cardIn 700ms cubic-bezier(.16,1,.3,1) both"};}
          .glassCard:nth-child(2){animation-delay:${reduceMotion ? "0ms" : "70ms"};}
          .glassCard:nth-child(3){animation-delay:${reduceMotion ? "0ms" : "140ms"};}
          .glassCard:hover{transform:scale(1.035);border-color:rgba(255,255,255,0.30);box-shadow:0 26px 90px rgba(0,0,0,0.34),inset 0 1px 0 rgba(255,255,255,0.22);filter:brightness(1.03);}
          .glassCard:active{transform:scale(1.015);}
          .glassCard:disabled{opacity:.78;cursor:not-allowed;transform:none;filter:none;}
          .glassShine{position:absolute;inset:-120px;background:radial-gradient(circle at 20% 20%, rgba(255,255,255,0.24), rgba(255,255,255,0.06), transparent 60%);opacity:.75;filter:blur(18px);pointer-events:none;animation:${reduceMotion ? "none" : "shineSweep 5.2s ease-in-out infinite"};}
          .cardTop{display:flex;justify-content:space-between;align-items:center;gap:10px;position:relative;z-index:2;}
          .chip{display:inline-flex;align-items:center;justify-content:center;height:38px;padding:0 14px;border-radius:999px;font-weight:1000;background:rgba(0,0,0,0.18);border:1px solid rgba(255,255,255,0.16);box-shadow:inset 0 1px 0 rgba(255,255,255,0.12);}
          .micro{font-size:12px;font-weight:950;letter-spacing:1.2px;opacity:.82;text-transform:uppercase;}
          .cardTitle{margin-top:20px;font-family:var(--font-display);font-size:clamp(24px,2.8vw,40px);font-weight:800;letter-spacing:-0.2px;position:relative;z-index:2;text-shadow:0 18px 60px rgba(0,0,0,0.26);}
          .cardHint{margin-top:12px;font-size:13px;font-weight:900;opacity:.85;position:relative;z-index:2;}

          /* Gewählte Karte: ruhig gelb umrandet (kein Blinken) */
          .glassCard.active{
            border-color: #ffd23f;
            background: rgba(255,210,63,0.20);
            box-shadow: 0 0 0 4px rgba(255,210,63,0.28), 0 22px 60px rgba(60,8,0,0.4);
            transform: translateY(-3px);
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
          @media (max-width: 520px){
            .bottomLeft{ display: none; }
            .barWrap{ min-width: 0; }
            .bottomInner{ padding: 10px 14px; }
            .topicGrid{ padding-bottom: 76px; }
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
            if (c === 3) return lobby.topic_c ? `③ ${cLabel}` : `🎲 Zufall`;
            return String(c);
        };

        const isWinner = (c: 1 | 2 | 3) => winnerChoice === c;

        return (
            <main
                className="fullH"
                style={{
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    color: "white",
                }}
            >
                <div style={{ width: "min(1100px, calc(100vw - 48px))", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>PLAYLIST GEWÄHLT</div>

                    <div className="resultTriGrid">
                        <div className={`resultTile ${isWinner(1) ? "win" : "lose"}`} style={plStyle(lookA.color)}>
                            <div className="resultBadge">①</div>
                            <div className="resultTitle">{aLabel}</div>
                        </div>
                        {voteCards >= 2 ? (
<div className={`resultTile ${isWinner(2) ? "win" : "lose"}`} style={plStyle(lookB.color)}>
                            <div className="resultBadge">②</div>
                            <div className="resultTitle">{bLabel}</div>
                        </div>
                        ) : null}
                        {voteCards >= 3 ? (
<div className={`resultTile ${isWinner(3) ? "win" : "lose"}`} style={plStyle(lookC.color)}>
                            <div className="resultBadge">{lobby.topic_c ? "③" : "🎲"}</div>
                            <div className="resultTitle">{isWinner(3) && !lobby.topic_c ? `Zufall: ${selectedTopic}` : cLabel}</div>
                        </div>
                        ) : null}
                    </div>

                    <div className="cdTopic" style={{ fontSize: "clamp(28px, 4.2vw, 52px)", fontWeight: 950, marginTop: 18 }}>
                        <span className="cdTopicIcon" aria-hidden>
                            {playlistLook(selectedTopic).icon}
                        </span>{" "}
                        {selectedTopic}
                    </div>

                    {tie ? (
                        <div style={{ marginTop: 10, opacity: 0.9, fontWeight: 850 }}>
                            Gleichstand zwischen: <span style={{ opacity: 0.98 }}>{tieChoices.map((c) => labelForChoice(c)).join(" · ")}</span>
                            <div style={{ marginTop: 6, opacity: 0.92 }}>
                                Das Los entscheidet: <b>{pick ? labelForChoice(pick) : "…"}</b>
                            </div>
                        </div>
                    ) : (
                        <div style={{ marginTop: 10, opacity: 0.85, fontWeight: 800 }}>Gleich läuft der erste Song.</div>
                    )}

                    <div style={{ marginTop: 22, fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>START IN</div>
                    <div style={{ marginTop: 10, fontSize: "clamp(80px, 10vw, 140px)", fontWeight: 950, letterSpacing: 2, textShadow: "0 18px 70px rgba(0,0,0,0.35)" }}>
                        <span key={Math.max(0, countdownSecondsLeft ?? 5)} className="cdNum">
                            {Math.max(0, countdownSecondsLeft ?? 5)}
                        </span>
                    </div>

                    {/* Nur der Startspieler sieht diesen Hinweis -- alle anderen
                        erfahren es erst, wenn die Runde wirklich losgeht. */}
                    {mePlayerId && lobby.countdown_starter_player_id === mePlayerId ? (
                        <div
                            style={{
                                marginTop: 12,
                                display: "inline-flex",
                                alignItems: "center",
                                gap: 8,
                                padding: "8px 16px",
                                borderRadius: 999,
                                background: "rgba(255,214,10,0.16)",
                                border: "1px solid rgba(255,214,10,0.4)",
                                fontWeight: 900,
                                fontSize: 14,
                            }}
                        >
                            🥔 Du startest gleich!
                        </div>
                    ) : null}

                    <ToastStack toasts={toasts} inline />
                </div>

                <style>{`
          .resultTriGrid{margin-top:16px;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px;align-items:stretch;}
          @media (max-width: 760px){ .resultTriGrid{grid-template-columns:1fr;} }
          .resultTile{border-radius:26px;border:2px solid rgba(255,255,255,0.16);background:rgba(38,9,6,0.46);padding:16px 14px;text-align:left;backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);overflow:hidden;position:relative;transform-origin:center;}
          .resultBadge{display:inline-flex;align-items:center;justify-content:center;height:34px;padding:0 12px;border-radius:999px;font-weight:950;background:rgba(255,255,255,0.12);border:1px solid rgba(255,255,255,0.14);}
          .resultTitle{margin-top:14px;font-size:clamp(18px,2.2vw,28px);font-weight:950;text-shadow:0 10px 30px rgba(0,0,0,0.22);}
          @keyframes winPop {0%{transform:scale(1);filter:brightness(1);}70%{transform:scale(1.06);filter:brightness(1.18);}100%{transform:scale(1.04);filter:brightness(1.12);}}
          @keyframes loseSlide {0%{transform:scale(1);opacity:1;}100%{transform:translateY(14px) scale(0.92);opacity:0.12;}}
          .resultTile.win{background:rgba(255,210,63,0.22);border-color:#ffd23f;box-shadow:0 0 0 4px rgba(255,210,63,0.25),0 18px 60px rgba(60,8,0,0.35);animation:winPop .55s ease-out forwards;}
          .resultTile.lose{animation:loseSlide .55s ease-out forwards;}
          @media (max-width: 860px){ main div[style*="gridTemplateColumns: repeat(3"]{ grid-template-columns: 1fr !important; } }
        `}</style>
            </main>
        );
    }

    // =========================================================
    // PHASE: FINISHED  (Winner-only hero, NO Top3 podium)
    // - Awards: Fastest Pass + Longest Hold
    // - Ranking: # | Name | Score | Runden | Fastest | Slowest
    // =========================================================
    if (lobby.phase === "finished") {
        const isSeries = (lobby.series_total ?? 1) > 1;
        const winnerName = (isSeries ? seriesLeader?.name : null) ?? winnerPlayer?.name ?? "Unbekannt";

        const fastestOverall =
            [...ranking].filter((r) => r.fastest != null).sort((a, b) => (a.fastest ?? 9e9) - (b.fastest ?? 9e9))[0] ?? null;
        const longestHold = [...ranking].sort((a, b) => b.holdMs - a.holdMs)[0] ?? null;
        const bestSong = [...ranking].filter((r) => r.songPoints > 0).sort((a, b) => b.songPoints - a.songPoints)[0] ?? null;

        const highlights: FinishHighlight[] = [];
        if (bestSong) highlights.push({ icon: "🎵", label: "Song-Profi", name: bestSong.name, value: `${String(Math.round(bestSong.songPoints * 2) / 2).replace(".", ",")} Treffer` });
        if (fastestOverall) highlights.push({ icon: "⚡", label: "Schnellster Pass", name: fastestOverall.name, value: fmtMs(fastestOverall.fastest) });
        if (longestHold && longestHold.holdMs > 0) highlights.push({ icon: "🧱", label: "Längste Haltezeit", name: longestHold.name, value: fmtHold(longestHold.holdMs) });

        const me = isSeries
            ? mySeriesRank > 0
                ? { place: mySeriesRank, score: seriesRanked.find((e) => e.id === mePlayerId)?.total ?? 0 }
                : null
            : myRankRow
              ? { place: myRankRow.rank, score: myRankRow.row.score }
              : null;

        const doRematch = async () => {
            if (endActionBusy || !mePlayerId) return;
            setEndActionBusy("rematch");
            const { error } = await supabase.rpc("rpc_rematch", { p_code: code, p_player_id: mePlayerId });
            if (error) {
                setEndActionBusy(null);
                return showToast(`❌ Rematch: ${error.message}`, 2400);
            }
            // Realtime / Polling wechselt gleich in die Themenwahl.
        };
        const doLobby = async () => {
            if (endActionBusy || !mePlayerId) return;
            setEndActionBusy("reset");
            const { error } = await supabase.rpc("rpc_reset_lobby", { p_code: code, p_player_id: mePlayerId });
            if (error) {
                setEndActionBusy(null);
                return showToast(`❌ Reset: ${error.message}`, 2400);
            }
            window.location.href = `/lobby/${encodeURIComponent(code)}`;
        };

        return (
            <main
                className="fullH"
                style={{
                    display: "grid",
                    placeItems: "start center",
                    padding: "28px 16px",
                    color: "white",
                    position: "relative",
                    overflow: "hidden",
                }}
            >
                <AchievementToastPortal achievements={newAchievements} onDismiss={dismissAchievement} />
                <Confetti active />
                <BackdropFx variant="warm" rays vignette />
                <FinishScreen
                    isSeries={isSeries}
                    totalRounds={lobby.series_total ?? 1}
                    winnerName={winnerName}
                    me={me}
                    rows={ranking.map((r) => ({
                        id: r.player_id,
                        name: r.name,
                        place: r.place,
                        score: r.score,
                        songPoints: r.songPoints,
                        moves: r.roundsSurvived,
                        isMe: r.player_id === mePlayerId,
                    }))}
                    seriesRows={seriesRows}
                    shareRows={
                        isSeries
                            ? seriesRanked.map((e, i) => ({ place: i + 1, name: e.name, score: e.total, isMe: e.id === mePlayerId }))
                            : ranking.map((r) => ({ place: r.place, name: r.name, score: r.score, isMe: r.player_id === mePlayerId }))
                    }
                    mePlayerId={mePlayerId}
                    highlights={highlights}
                    loggedIn={!!user}
                    ranked={players.filter((p) => !p.is_bot).length >= 2}
                    spectator={isSpectator}
                    busy={endActionBusy}
                    onRematch={() => void doRematch()}
                    onLobby={() => void doLobby()}
                    toasts={toasts}
                />
            </main>
        );
    }

    // =========================================================
    // PHASE: REMATCH_WAIT
    // =========================================================
    // rpc_rematch setzt diese Phase UND einen 10s-Countdown
    // (countdown_started_at/countdown_ends_at). Kein Bereit-Toggle mehr --
    // der erste Tastendruck auf "R" reicht, alle Anwesenden starten nach
    // Ablauf automatisch mit, ohne dass jeder einzeln nochmal bestätigen
    // muss.
    if (lobby.phase === "set_summary") {
        const idx = lobby.series_index ?? 1;
        const total = lobby.series_total ?? 1;
        const setRows = seriesRows.filter((r) => r.set_index === idx).sort((a, b) => a.place - b.place);
        const setWinner = setRows[0]?.name ?? "…";

        return (
            <main
                className="fullH"
                style={{
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    color: "white",
                }}
            >
                <div style={{ width: "min(860px, calc(100vw - 48px))", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>
                        RUNDE {idx} VON {total} · ZWISCHENSTAND
                    </div>
                    <div style={{ fontSize: "clamp(26px, 4vw, 44px)", fontWeight: 950, marginTop: 10 }}>🏆 {setWinner} holt die Runde</div>

                    <div style={{ marginTop: 18, textAlign: "left" }}>
                        <SeriesTable rows={seriesRows} totalSets={total} playedSets={idx} mePlayerId={mePlayerId} title="Zwischenstand" />
                    </div>

                    <div style={{ marginTop: 20, opacity: 0.85, fontWeight: 800 }}>
                        Nächste Runde: Themen-Voting in
                    </div>
                    <div style={{ fontSize: "clamp(48px, 7vw, 84px)", fontWeight: 950, textShadow: "0 14px 50px rgba(0,0,0,0.35)" }}>
                        {Math.max(0, countdownSecondsLeft ?? 12)}
                    </div>
                    <ToastStack toasts={toasts} inline />
                </div>
            </main>
        );
    }

    if (lobby.phase === "rematch_wait") {
        return (
            <main
                className="fullH"
                style={{
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    color: "white",
                }}
            >
                <div style={{ width: "min(680px, calc(100vw - 48px))", textAlign: "center" }}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>REMATCH</div>
                    <div style={{ fontSize: "clamp(26px, 4vw, 42px)", fontWeight: 950, marginTop: 12 }}>🔁 Nächstes Match startet gleich</div>
                    <div style={{ marginTop: 8, opacity: 0.82, fontWeight: 700 }}>
                        Alle Anwesenden gehen automatisch weiter zur Themenwahl.
                    </div>

                    <div style={{ marginTop: 18, fontSize: "clamp(56px, 8vw, 96px)", fontWeight: 950, textShadow: "0 14px 50px rgba(0,0,0,0.35)" }}>
                        {Math.max(0, countdownSecondsLeft ?? 10)}
                    </div>

                    <div style={{ marginTop: 22, display: "flex", flexWrap: "wrap", gap: 8, justifyContent: "center" }}>
                        {players.map((p) => (
                            <span
                                key={p.player_id}
                                style={{
                                    padding: "8px 14px",
                                    borderRadius: 999,
                                    background: "rgba(38,9,6,0.46)",
                                    border: "1px solid rgba(255,255,255,0.18)",
                                    fontWeight: 800,
                                    fontSize: 14,
                                }}
                            >
                                ✅ {p.name}
                                {mePlayerId === p.player_id ? " (du)" : ""}
                            </span>
                        ))}
                    </div>

                    <ToastStack toasts={toasts} inline />
                </div>

            </main>
        );
    }

    // =========================================================
    // PHASE: NOT RUNNING
    // =========================================================
    if (lobby.phase !== "running") {
        return (
            <main
                className="fullH"
                style={{
                    display: "grid",
                    placeItems: "center",
                    padding: 24,
                    color: "white",
                }}
            >
                <div style={{ width: "min(820px, calc(100vw - 48px))", textAlign: "center" }}>
                    {isSpectator && (lobby.phase === "waiting" || lobby.phase === "lobby") ? (
                        <>
                            <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: 1.6, opacity: 0.75 }}>{t("spec.kicker")}</div>
                            <div style={{ fontSize: "clamp(28px, 4vw, 46px)", fontWeight: 950, marginTop: 12 }}>
                                {lobby.locked ? t("spec.lockedTitle") : t("spec.openTitle")}
                            </div>
                            <div style={{ marginTop: 10, opacity: 0.82, fontWeight: 700 }}>{lobby.locked ? t("spec.lockedSub") : t("spec.openSub")}</div>
                            {!lobby.locked ? (
                                <div style={{ marginTop: 18 }}>
                                    <a className="btn btnPrimary" href={`/join?code=${encodeURIComponent(code)}`}>
                                        {t("spec.joinBtn")}
                                    </a>
                                </div>
                            ) : null}
                        </>
                    ) : players.length === 0 || (players.length === 1 && !!mePlayerId && players[0]?.player_id === mePlayerId) ? (
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
        ? "radial-gradient(circle at 50% 28%, rgba(120,130,150,0.22) 0%, rgba(10,12,18,0) 62%), linear-gradient(180deg, #171a22 0%, #0f1218 60%, #0a0c11 100%)"
        : "radial-gradient(circle at 50% 28%, rgba(60,110,190,0.30) 0%, rgba(10,16,34,0) 62%), linear-gradient(180deg, #121a33 0%, #0c1226 55%, #080c1c 100%)";

    const passDisabledReason = iAmEliminated ? "Du bist raus" : !isMeHolder ? "Nicht dein Turn" : passBusy ? "Busy" : null;

    const aliveNow = players.filter((p) => p.is_alive).length;

    // Heat-Ratio (0..1): kontinuierlich statt nur 3 Stufen, damit man nach
    // einem Pass sofort sieht, WIE WEIT die aktuelle Runde schon ist, statt
    // nur "ruhig/mittel/heiß" grob zu erahnen. Bezugsgröße ist die Dauer
    // DIESER Halter-Runde (roundTotalMsRef, ab dem letzten Halterwechsel),
    // nicht ein fixer Wert -- Blitz/Standard/Casual haben ja unterschiedlich
    // lange Runden.
    const heatRatio = clamp(
        explodeMsLeft == null || roundTotalMsRef.current <= 0 ? 0 : 1 - explodeMsLeft / roundTotalMsRef.current,
        0,
        1
    );

    // Tempo-Anzeige: spiegelt calc_explode_seconds (-6 % Schnurlänge pro
    // Eliminierung, Boden 45 %) und im Duell nochmal 20 % kürzer.
    const tempoFactor =
        (1 / Math.max(0.45, 1 - (Math.max(1, lobby.round_number ?? 1) - 1) * 0.06)) * (aliveNow === 2 ? 1.25 : 1);

    return (
        <main
            className={`fullH${selfShake ? " kumpirSelfShake" : ""}`}
            style={{ width: "100%", position: "relative", overflow: "hidden", background: runningBg, color: "white" }}
        >
            {/* Feuerwellen am Bildschirmrand -- Intensität/Pulstempo skalieren
                kontinuierlich mit heatRatio, statt in 3 groben Sprüngen, damit
                man nach einem Pass sofort ein Gefühl dafür hat, wie weit die
                Runde schon ist. */}
            <div className="edgeFire" style={{ ["--heat" as string]: heatRatio }} aria-hidden />

            <PlayerRing
                players={players}
                holderPlayerId={lobby.holder_player_id}
                mePlayerId={mePlayerId}
                passEvent={passEvent}
                explodedPlayerId={explodedPlayerId}
                disconnectedIds={disconnectedIds}
                heat={heatRatio}
                round={Math.max(1, lobby.round_number ?? 1)}
                tempo={tempoFactor}
                duel={aliveNow === 2}
                direction={lobby.pass_direction ?? 1}
                showNext={isMeHolder || iAmEliminated}
            />

            {turnOverlay ? (
                <div className="turnOverlay" role="status" aria-live="polite">
                    ✅ Du bist dran
                </div>
            ) : null}

            {elimPopup ? (
                <div key={elimPopup.key} className={`elimPopup ${elimPopup.kind}`} role="status" aria-live="assertive">
                    {elimPopup.kind === "out" ? "💥 " : "🥔 "}
                    {elimPopup.text}
                </div>
            ) : null}

            {/* Top-right: Modus + Heat + Connection + Audio */}
            <div className="topRight" aria-hidden={false}>
                {(lobby.series_total ?? 1) > 1 ? (
                    <div className="modePill modePillBig" title="Runde des Matches">
                        <span>🎯</span>
                        <span>{lobby.series_index}/{lobby.series_total}</span>
                    </div>
                ) : null}
                <div className="modePill modePillBig" title={`${aliveNow} von ${totalPlayers} Spielern noch am Leben`}>
                    <span>👥</span>
                    <span>{aliveNow}/{totalPlayers}</span>
                </div>
                <AudioControl />
            </div>

            {/* Host-Live-Kick: da Antworten immer akzeptiert werden, kann der
                Host hier sofort (ohne Bestätigung) einen aktiven Spieler
                eliminieren, z.B. wenn die getippte Antwort offensichtlich
                falsch war. Nur für den Host sichtbar, verschiebt nichts
                anderes im Layout (eigene fixierte Box). */}
            {isHost ? (
                <div className="hostKickPanel">
                    <button type="button" className="hostKickLabel" onClick={() => setKickOpen((v) => !v)} aria-expanded={kickOpen}>
                        👑 Kicken {kickOpen ? "▴" : "▾"}
                    </button>
                    <div className="hostKickList" style={{ display: kickOpen ? "flex" : "none" }}>
                        {players
                            .filter((p) => p.is_alive && p.player_id !== mePlayerId)
                            .map((p) => (
                                <button
                                    key={p.player_id}
                                    type="button"
                                    className="hostKickChip"
                                    onClick={() => void handleHostKick(p.player_id)}
                                    disabled={kickBusyId === p.player_id}
                                    title={`${p.name} sofort eliminieren`}
                                >
                                    {kickBusyId === p.player_id ? "…" : `✖ ${p.name}`}
                                </button>
                            ))}
                    </div>
                </div>
            ) : null}

            {/* Self-elimination flash overlay */}
            {selfShake ? <div className="selfFlash" aria-hidden /> : null}

            <ToastStack toasts={toasts} />

            <div className="hud">
                <div className="hudInner">
                    <div className="topicRow">
                        <span className="topicPill">🎵 {selectedTopic}</span>
                        <span className="topicPill hudMeta">Zug {Math.max(1, lobby.round_number ?? 1)}</span>
                        <span className="topicPill hudMeta">{aliveNow === 2 ? "⚔ Duell" : `⚡ ×${tempoFactor.toFixed(1)}`}</span>
                    </div>

                    {MUSIC_PLAYLISTS[selectedTopic] ? (
                        <SongRound songId={lobby.current_song_id} startedAt={lobby.current_song_started_at} />
                    ) : null}

                    <div className="srOnly" key={hudPulseNonce} aria-live="polite">
                        Am Zug: {holderName}.
                    </div>

                    {iAmEliminated ? (
                        <div className="statusCard">
                            <div className="statusTitle">Du bist raus – schau zu 👀</div>
                            <div className="statusSub">Du siehst, wohin die Kumpir als Nächstes fliegt.</div>
                            {(lobby.game_mode ?? "original") === "original" && !meRow?.revenge_used && aliveNow > 2 ? (
                                <button
                                    type="button"
                                    className="btn btnSecondary btnSmall"
                                    onClick={() => void handleRevenge()}
                                    disabled={revengeBusy}
                                    title="Einmal pro Runde: die Richtung der Weitergabe drehen"
                                >
                                    🔄 Rache-Pass: Richtung drehen
                                </button>
                            ) : null}
                        </div>
                    ) : isMeHolder ? (
                        <div className="answerCard">
                            <div className="answerHead">
                                <div className="statusTitle">Du bist dran! 🥔</div>
                                {lobby.current_song_id ? (
                                    <div className="diffChip" title="Schwierigkeit des Songs – schwere Songs geben mehr Bonuszeit">
                                        {"★".repeat(lobby.current_song_difficulty ?? 2)}
                                        {"☆".repeat(3 - (lobby.current_song_difficulty ?? 2))}
                                    </div>
                                ) : null}
                            </div>
                            <div className="statusSub">
                                {lobby.current_song_id ? "Welcher Song läuft? Tippe den Titel (oder den Interpreten) und drücke Enter." : "Tippe deine Antwort und drücke Enter."}
                            </div>
                            <div className="answerInputRow">
                                <input
                                    ref={answerInputRef}
                                    type="text"
                                    className={`input answerInput ${answerWrong ? "answerInputWrong" : ""}`}
                                    value={answerDraft}
                                    onChange={(e) => setAnswerDraft(e.target.value)}
                                    onKeyDown={(e) => {
                                        if (e.key === "Enter" && !passBusy) {
                                            e.preventDefault();
                                            void handleAttemptPass();
                                        }
                                    }}
                                    placeholder={lobby.current_song_id ? "Songtitel …" : "Deine Antwort …"}
                                    maxLength={60}
                                    autoFocus
                                    autoComplete="off"
                                    autoCapitalize="none"
                                    autoCorrect="off"
                                    spellCheck={false}
                                    inputMode="text"
                                    enterKeyHint="send"
                                    aria-label="Antwort"
                                />
                            </div>
                            <div className={`answerFeedback ${answerWrong ? "show" : ""}`} aria-live="polite">
                                {answerWrong ? "Nicht richtig – versuch es nochmal!" : "\u00A0"}
                            </div>
                            <button
                                type="button"
                                className="btn btnPrimary answerSend"
                                onClick={() => void handleAttemptPass()}
                                disabled={!!passDisabledReason || answerDraft.trim().length === 0}
                                title={passDisabledReason ?? "Antwort senden (Enter)"}
                            >
                                {passBusy ? "…" : "Senden  ⏎"}
                            </button>
                            {lobby.current_song_id && (meRow?.skips_left ?? 0) > 0 ? (
                                <button
                                    type="button"
                                    className="linkBtn"
                                    onClick={() => void handleSkipSong()}
                                    disabled={skipBusy || passBusy}
                                    title="Song tauschen (einmal pro Runde, kostet 2 Sekunden)"
                                >
                                    🔀 Song tauschen (−2 s)
                                </button>
                            ) : null}
                        </div>
                    ) : (
                        <div className="statusCard">
                            <div className="statusTitle">{holderName} ist dran</div>
                            <div className="statusSub">{isSpectator ? "Du schaust nur zu – in der nächsten Runde kannst du mitspielen." : "Warte ab – gleich kann es dich treffen."}</div>
                        </div>
                    )}

                    {/* Used-Answers: bisher genannte Antworten dieser Runde --
                        zeigt die letzten 10, für lebende wie eliminierte Spieler
                        gleichermaßen sichtbar (dieser Block hängt nicht an
                        iAmEliminated). */}
                    {lobby.used_answers && lobby.used_answers.length > 0 ? (
                        <div className="usedAnswers" aria-label="Bisher genannte Antworten">
                            <span className="usedAnswersLabel">Schon gesagt</span>
                            {lobby.used_answers.slice(-10).map((a, i) => (
                                <span key={`${a}-${i}`} className="usedAnswerChip">{a}</span>
                            ))}
                            {lobby.used_answers.length > 10 ? (
                                <span className="usedAnswerChip more">+{lobby.used_answers.length - 10}</span>
                            ) : null}
                        </div>
                    ) : null}
                </div>
            </div>

            <style>{`
        .srOnly{ position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0); white-space:nowrap; }
        .hud{
          position: relative;
          z-index: 3;
          min-height: 100vh;
          min-height: 100dvh;
          display: grid;
          place-items: start center;
          align-content: start;
          padding: 22px;
          /* Platz für den Tisch (PlayerRing) darüber, damit Antwort-Box und
             Tisch nicht übereinander liegen. */
          padding-top: calc(27vh + min(66vmin, 540px) * 0.31 + 128px);
        }
        .hudInner{
          width: min(920px, 94vw);
          display: grid;
          justify-items: center;
          gap: 14px;
          text-align: center;
        }
        .topicRow{ display:flex; justify-content:center; gap: 8px; flex-wrap: wrap; }
        .hudMeta{ display: none; }
        @media (max-width: 520px){
          .hudMeta{ display: inline-block; }
          .hud{ padding-top: calc(27vh + 70vmin * 0.31 + 76px); }
          .topicRow .topicPill{ font-size: 12px; padding: 5px 10px; }
          .topicRow{ flex-wrap: nowrap; }
        }
        .topicPill{
          font-size: 14px;
          font-weight: 800;
          letter-spacing: .3px;
          padding: 7px 16px;
          border-radius: 999px;
          background: rgba(255,255,255,0.10);
          border: 1px solid rgba(255,255,255,0.18);
          color: rgba(255,255,255,0.92);
        }
        .statusCard, .answerCard{
          width: min(560px, 94vw);
          display: grid;
          gap: 10px;
          justify-items: center;
          padding: 18px 20px;
          border-radius: 24px;
          background: rgba(255,255,255,0.07);
          border: 1px solid rgba(255,255,255,0.14);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
        }
        .answerCard{
          border-color: rgba(255,214,10,0.55);
          box-shadow: 0 0 0 4px rgba(255,214,10,0.10), 0 18px 50px rgba(0,0,0,0.35);
        }
        .statusTitle{ font-size: clamp(20px, 3.2vw, 28px); font-weight: 900; letter-spacing: -0.01em; }
        .statusSub{ font-size: 14px; opacity: .72; font-weight: 600; max-width: 42ch; }
        .answerHead{ display:flex; align-items:center; gap:12px; justify-content:center; }
        .answerCard .answerInputRow{ width: 100%; }
        .answerSend{ width: 100%; }
        .answerFeedback{ min-height: 20px; font-size: 14px; font-weight: 800; color: #ffb4a8; opacity: 0; transition: opacity .2s ease; }
        .answerFeedback.show{ opacity: 1; }
        .linkBtn{
          background: none; border: 0; color: rgba(255,255,255,0.78); font-weight: 700; font-size: 13px;
          cursor: pointer; text-decoration: underline; text-underline-offset: 3px; padding: 4px 8px;
        }
        .linkBtn:hover{ color: #fff; }
        .linkBtn:disabled{ opacity: .5; cursor: default; }

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
        .diffChip{
          justify-self: center;
          font-size: 12px;
          font-weight: 900;
          letter-spacing: .6px;
          padding: 4px 12px;
          border-radius: 999px;
          background: rgba(0,0,0,.35);
          border: 1px solid rgba(255,214,10,.4);
          color: #ffe08a;
        }
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
        .answerInputWrong{
          animation: answerWrongFlash 0.5s ease-out;
        }
        @keyframes answerWrongFlash{
          0%{ border-color: rgba(255,59,48,0.95); box-shadow: 0 0 0 4px rgba(255,59,48,0.35); }
          70%{ border-color: rgba(255,59,48,0.7); box-shadow: 0 0 0 2px rgba(255,59,48,0.15); }
          100%{ border-color: rgba(255,255,255,0.18); box-shadow: none; }
        }
        @media (prefers-reduced-motion: reduce){
          .answerInputWrong{ animation: none; border-color: rgba(255,59,48,0.9); }
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
        .elimPopup{
          position: fixed;
          left: 50%;
          top: 9%;
          transform: translate(-50%, 0);
          z-index: 9998;
          max-width: min(560px, calc(100vw - 32px));
          padding: 16px 28px;
          border-radius: 20px;
          background: rgba(12,16,24,0.82);
          border: 1px solid rgba(255,255,255,0.22);
          box-shadow: 0 20px 60px rgba(0,0,0,0.45);
          backdrop-filter: blur(12px);
          -webkit-backdrop-filter: blur(12px);
          font-size: clamp(20px, 3.8vw, 30px);
          font-weight: 950;
          text-align: center;
          pointer-events: none;
          animation: elimPopupLife 2s ease both;
        }
        .elimPopup.out{ border-color: rgba(255,120,90,0.65); box-shadow: 0 20px 60px rgba(0,0,0,0.45), 0 0 34px rgba(255,100,70,0.3); }
        .elimPopup.left{ border-color: rgba(255,214,10,0.55); font-size: clamp(18px, 3.2vw, 26px); }
        @keyframes elimPopupLife{
          0% { opacity: 0; transform: translate(-50%, -10px) scale(0.94); }
          12% { opacity: 1; transform: translate(-50%, 0) scale(1.03); }
          20% { transform: translate(-50%, 0) scale(1); }
          72% { opacity: 1; transform: translate(-50%, 0) scale(1); }
          100% { opacity: 0; transform: translate(-50%, -6px) scale(0.98); }
        }
        @media (prefers-reduced-motion: reduce){
          .elimPopup{ animation: none; }
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
        .modePillBig{
          padding: 10px 18px;
          font-size: 17px;
          gap: 8px;
        }

        .hostKickPanel{
          position: fixed;
          top: 18px;
          left: 18px;
          z-index: 60;
          max-width: min(52vw, 320px);
          padding: 8px 10px;
          border-radius: 16px;
          background: rgba(0,0,0,0.26);
          border: 1px solid rgba(255,255,255,0.16);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
        }
        .hostKickLabel{
          font-size: 12px;
          font-weight: 900;
          letter-spacing: 0.4px;
          color: #fff;
          background: none;
          border: 0;
          padding: 2px 4px;
          cursor: pointer;
          opacity: 0.8;
        }
        .hostKickList{ margin-top: 6px; }
        .hostKickList{
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
        }
        .hostKickChip{
          border: 1px solid rgba(255,90,90,0.4);
          background: rgba(255,45,45,0.16);
          color: #fff;
          font-weight: 800;
          font-size: 12px;
          padding: 5px 10px;
          border-radius: 999px;
          cursor: pointer;
        }
        .hostKickChip:hover{ background: rgba(255,45,45,0.3); }
        .hostKickChip:disabled{ opacity: 0.5; cursor: default; }

        .edgeFire{
          position: fixed;
          inset: 0;
          z-index: 3;
          pointer-events: none;
          --heat: 0;
          opacity: var(--heat);
          box-shadow: inset 0 0 calc(30px + var(--heat) * 80px) calc(0px + var(--heat) * 8px) rgba(255,130,50,0.28);
          animation: edgeFirePulse calc(3.2s - var(--heat) * 2.2s) ease-in-out infinite;
          transition: opacity 400ms ease, box-shadow 400ms ease;
        }
        @keyframes edgeFirePulse{
          0%,100%{ filter: brightness(1) saturate(1); }
          50%{ filter: brightness(calc(1 + var(--heat) * 0.55)) saturate(calc(1 + var(--heat) * 0.35)); }
        }
        @media (prefers-reduced-motion: reduce){
          .edgeFire{ animation: none; }
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


        @media (max-width: 520px){
          .strip{ grid-template-columns: 1fr; gap: 10px; border-radius: 28px; }
          .arrow{ display:none; }
          .now,.next{ justify-content: center; }
        }
      `}</style>
        </main>
    );
}

/** Hülle: zeigt über allen Spielphasen ein Zuschauer-Schild, wenn man nicht mitspielt. */
export default function GamePage() {
    const { t } = useI18n();
    const [spectator, setSpectator] = useState(false);
    return (
        <>
            {spectator ? (
                <div className="spectatorBadge" role="status">
                    {t("game.spectating")}
                </div>
            ) : null}
            <GamePageInner onSpectator={setSpectator} />
        </>
    );
}
