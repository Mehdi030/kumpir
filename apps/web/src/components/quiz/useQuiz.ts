"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { serverNow } from "@/lib/serverClock";
import { errorText } from "@/lib/errorText";
import { playFx } from "@/lib/gameFx";
import type { AvatarConfig } from "@/components/game/PlayerAvatar";

/** Lobby-Felder, die die Quiz-Modi brauchen (Migration 108/118). */
export type QuizLobby = {
    code: string;
    game_mode: string | null;
    topic_selected: string | null;
    series_index: number;
    series_total: number;
    current_song_id: string | null;
    current_song_started_at: string | null;
    quiz_state: string | null;
    quiz_index: number;
    quiz_total: number;
    quiz_target: number | null;
    /** Jahr raten: Zeitleiste { yearMin, yearMax } */
    quiz_options: Record<string, unknown> | null;
    quiz_seq: number;
    quiz_rev: number;
    quiz_started_at: string | null;
    quiz_ends_at: string | null;
    quiz_picker: string | null;
    quiz_reveal: Record<string, unknown> | null;
    quiz_locked: string[];
    /** Buzzer: Protokoll der Versuche (Migration 124) */
    quiz_log?: QuizLogEntry[] | null;
};

/** Ein Buzzer-Versuch: p = Spieler, a = Eingabe (null = keine Eingabe), ok = richtig, pts = Punkte (+2/+1 oder -1/0) */
export type QuizLogEntry = { seq: number; p: string; a: string | null; ok: boolean; pts: number };

export type QuizPlayer = {
    player_id: string;
    name: string;
    song_points?: number;
    avatar_config?: AvatarConfig | null;
    is_bot?: boolean;
};

export type RevealResult = { playerId: string; points: number; correct: boolean; answer: string | null };

type Status = {
    seq: number;
    /** Roulette: meine bisherigen Eingaben und wer schon "fertig" ist */
    mine?: string[];
    done?: string[];
    /** Roulette: meine Stimme (1–3) bei der Kategorie-Abstimmung und wer schon gewählt hat */
    myvote?: number | null;
    voted?: string[];
    /** Roulette: Einsprüche gegen rote Wörter (o = Besitzer, t = Text, y/n = Ja-/Nein-Stimmen, s = Stand) */
    appeals?: { o: string; t: string; y: string[]; n: string[]; s: "open" | "accepted" | "rejected" }[];
    me: { answered: boolean; correct?: boolean | null; points?: number; tries?: number; answer?: string | null };
    answered: string[];
};

export const pts = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(1).replace(".", ","));

function secondsLeft(endsAt: string | null): number {
    const t = endsAt ? Date.parse(endsAt) : NaN;
    return Number.isNaN(t) ? 0 : Math.max(0, (t - serverNow()) / 1000);
}

/**
 * Gemeinsame Logik der Quiz-Modi: Uhr + Server-Takt als Absicherung, eigener Status (schon getippt?),
 * Aktionen (buzzern, Antwort tippen, Jahr tippen) mit Fehlermeldung als Toast.
 */
export function useQuiz({ lobby, mePlayerId, onToast }: { lobby: QuizLobby; mePlayerId: string | null; onToast: (msg: string, ms?: number) => void }) {
    const supabase = getSupabaseClient();
    const [status, setStatus] = useState<Status | null>(null);
    const [busy, setBusy] = useState(false);
    const [, setNow] = useState(0);
    const tickBusy = useRef(false);

    // Uhr (Zeitbalken) + Takt: ist die Zeit um, stupst jeder Client den Server an (der Cron macht es auch)
    useEffect(() => {
        const t = window.setInterval(() => {
            setNow((n) => n + 1);
            if (lobby.quiz_ends_at && secondsLeft(lobby.quiz_ends_at) <= 0 && !tickBusy.current) {
                tickBusy.current = true;
                void supabase.rpc("rpc_quiz_tick", { p_code: lobby.code }).then(() => {
                    window.setTimeout(() => (tickBusy.current = false), 900);
                });
            }
        }, 200);
        return () => window.clearInterval(t);
    }, [lobby.quiz_ends_at, lobby.code, supabase]);

    // Eigener Status bei jeder Änderung neu laden
    useEffect(() => {
        if (!mePlayerId) return;
        let alive = true;
        void supabase.rpc("rpc_quiz_status", { p_code: lobby.code, p_player_id: mePlayerId }).then(({ data, error }) => {
            if (!alive || error || !data) return;
            setStatus(data as Status);
        });
        return () => {
            alive = false;
        };
    }, [supabase, lobby.code, mePlayerId, lobby.quiz_rev, lobby.quiz_seq, lobby.quiz_state]);

    const mine = status && status.seq === lobby.quiz_seq ? status : null;
    const meAnswered = !!mine?.me.answered;
    const answeredSet = useMemo(() => new Set(mine?.answered ?? []), [mine]);

    const total = useMemo(() => {
        const a = lobby.quiz_started_at ? Date.parse(lobby.quiz_started_at) : NaN;
        const b = lobby.quiz_ends_at ? Date.parse(lobby.quiz_ends_at) : NaN;
        return Number.isNaN(a) || Number.isNaN(b) ? 1 : Math.max(1, (b - a) / 1000);
    }, [lobby.quiz_started_at, lobby.quiz_ends_at]);
    const left = secondsLeft(lobby.quiz_ends_at);
    const ratio = Math.max(0, Math.min(1, left / total));

    const run = useCallback(
        async (fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>) => {
            if (busy) return null;
            setBusy(true);
            try {
                const { data, error } = await fn();
                if (error) {
                    onToast(`❌ ${errorText(error.message)}`, 2200);
                    return null;
                }
                return data ?? {};
            } finally {
                setBusy(false);
            }
        },
        [busy, onToast]
    );

    /** Buzzer drücken */
    const buzz = useCallback(async () => {
        if (!mePlayerId) return false;
        playFx("tick");
        return (await run(() => supabase.rpc("rpc_quiz_buzz", { p_code: lobby.code, p_player_id: mePlayerId }))) !== null;
    }, [mePlayerId, run, supabase, lobby.code]);

    /** Buzzer: Titel/Künstler tippen (nur für den, der gebuzzert hat) */
    const answer = useCallback(
        async (text: string) => {
            if (!mePlayerId) return null;
            const res = (await run(() => supabase.rpc("rpc_quiz_answer", { p_code: lobby.code, p_player_id: mePlayerId, p_answer: text }))) as { correct?: boolean; points?: number; half?: boolean } | null;
            if (res) playFx(res.correct ? "voteWin" : "wrong");
            return res;
        },
        [mePlayerId, run, supabase, lobby.code]
    );

    /** Jahr raten: Tipp abgeben */
    const guessYear = useCallback(
        async (year: number) => {
            if (!mePlayerId) return false;
            const res = await run(() => supabase.rpc("rpc_quiz_choose", { p_code: lobby.code, p_player_id: mePlayerId, p_choice: String(year) }));
            if (res) {
                playFx("vote");
                setStatus((s) => (s ? { ...s, me: { answered: true, correct: null, points: 0, answer: String(year) } } : s));
            }
            return res !== null;
        },
        [mePlayerId, run, supabase, lobby.code]
    );

    /** Jahr raten, Gleichstand: Monat (1–12) tippen */
    const guessMonth = useCallback(
        async (month: number) => {
            if (!mePlayerId) return false;
            const res = await run(() => supabase.rpc("rpc_quiz_choose", { p_code: lobby.code, p_player_id: mePlayerId, p_choice: String(month) }));
            if (res) {
                playFx("vote");
                setStatus((s) => (s ? { ...s, me: { answered: true, correct: null, points: 0, answer: String(month) } } : s));
            }
            return res !== null;
        },
        [mePlayerId, run, supabase, lobby.code]
    );

    /** Roulette: einen Begriff abgeben (ohne Rückmeldung, ob er stimmt). Liefert false, wenn er nicht gespeichert werden konnte. */
    const submitTerm = useCallback(
        async (text: string) => {
            if (!mePlayerId) return false;
            const { error } = await supabase.rpc("rpc_letters_submit", { p_code: lobby.code, p_player_id: mePlayerId, p_text: text });
            if (error) {
                if (/letters_too_many/.test(error.message)) onToast(errorText(error.message), 2200);
                return false;
            }
            return true;
        },
        [mePlayerId, supabase, lobby.code, onToast]
    );

    /** Roulette: für eine der drei Kategorien stimmen (1–3); umentscheiden ist erlaubt */
    const voteCategory = useCallback(
        async (choice: number) => {
            if (!mePlayerId) return false;
            const { error } = await supabase.rpc("rpc_letters_vote", { p_code: lobby.code, p_player_id: mePlayerId, p_choice: choice });
            if (error) return false;
            playFx("vote");
            setStatus((s) => (s ? { ...s, myvote: choice, voted: [...new Set([...(s.voted ?? []), mePlayerId])] } : s));
            return true;
        },
        [mePlayerId, supabase, lobby.code]
    );

    /** Roulette: "Fertig" – sind alle Menschen fertig, geht es sofort zur Auflösung */
    const finishTerms = useCallback(async () => {
        if (!mePlayerId) return;
        await supabase.rpc("rpc_letters_done", { p_code: lobby.code, p_player_id: mePlayerId });
        setStatus((s) => (s ? { ...s, done: [...(s.done ?? []), mePlayerId] } : s));
    }, [mePlayerId, supabase, lobby.code]);

    /** Roulette: Einspruch gegen ein eigenes rotes Wort */
    const appeal = useCallback(
        async (text: string) => {
            if (!mePlayerId) return false;
            const { error } = await supabase.rpc("rpc_letters_appeal", { p_code: lobby.code, p_player_id: mePlayerId, p_text: text });
            if (error) {
                onToast(`❌ ${errorText(error.message)}`, 2200);
                return false;
            }
            return true;
        },
        [mePlayerId, supabase, lobby.code, onToast]
    );

    /** Roulette: über den Einspruch eines anderen abstimmen (true = Daumen hoch) */
    const appealVote = useCallback(
        async (owner: string, text: string, yes: boolean) => {
            if (!mePlayerId) return false;
            const { error } = await supabase.rpc("rpc_letters_appeal_vote", { p_code: lobby.code, p_player_id: mePlayerId, p_owner: owner, p_text: text, p_yes: yes });
            if (error) {
                onToast(`❌ ${errorText(error.message)}`, 2200);
                return false;
            }
            return true;
        },
        [mePlayerId, supabase, lobby.code, onToast]
    );

    return { status: mine, meAnswered, answeredSet, busy, left, total, ratio, buzz, answer, guessYear, guessMonth, submitTerm, finishTerms, voteCategory, appeal, appealVote };
}
