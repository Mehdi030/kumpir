"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type PassAttempt = {
    id: string;
    lobby_id: string;
    round_number: number;
    holder_player_id: string;
    answer: string;
    topic: string;
    status: "pending" | "accepted" | "rejected" | "timeout";
    accept_count: number;
    reject_count: number;
    created_at: string;
    decided_at: string | null;
};

export type PassAttemptVote = {
    attempt_id: string;
    voter_id: string;
    accept: boolean;
};

type UsePassAttemptResult = {
    attempt: PassAttempt | null;
    myVote: boolean | null; // null = not voted, true = accept, false = reject
    refresh: () => Promise<void>;
};

/**
 * Loads the currently open pass-attempt for a lobby. Subscribes via realtime
 * so the UI re-renders instantly when somebody votes.
 *
 * Returns null when there's no open attempt (= holder hasn't started one yet,
 * or one was just accepted/rejected).
 */
export function usePassAttempt(
    lobbyId: string | null | undefined,
    currentAttemptId: string | null | undefined,
    mePlayerId: string | null | undefined
): UsePassAttemptResult {
    const supabase = getSupabaseClient();
    const [attempt, setAttempt] = useState<PassAttempt | null>(null);
    const [myVote, setMyVote] = useState<boolean | null>(null);

    const load = useCallback(async () => {
        if (!currentAttemptId) {
            setAttempt(null);
            setMyVote(null);
            return;
        }

        const attemptRes = await supabase
            .from("pass_attempts")
            .select("id,lobby_id,round_number,holder_player_id,answer,topic,status,accept_count,reject_count,created_at,decided_at")
            .eq("id", currentAttemptId)
            .maybeSingle();

        if (attemptRes.error || !attemptRes.data) {
            setAttempt(null);
            setMyVote(null);
            return;
        }

        setAttempt(attemptRes.data as unknown as PassAttempt);

        if (mePlayerId) {
            const voteRes = await supabase
                .from("pass_attempt_votes")
                .select("accept")
                .eq("attempt_id", currentAttemptId)
                .eq("voter_id", mePlayerId)
                .maybeSingle();
            const row = voteRes.data as { accept?: boolean } | null;
            setMyVote(row?.accept ?? null);
        }
    }, [supabase, currentAttemptId, mePlayerId]);

    // Initial + on-change load. The setState call inside `load` is exactly what
    // this effect needs to do: sync external state (the DB row) into React.
    useEffect(() => {
        // eslint-disable-next-line react-hooks/set-state-in-effect
        void load();
    }, [load]);

    // Realtime — react instantly to vote/status changes
    useEffect(() => {
        if (!lobbyId || !currentAttemptId) return;

        const channel = supabase
            .channel(`attempt:${currentAttemptId}`)
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "pass_attempts", filter: `id=eq.${currentAttemptId}` },
                () => void load()
            )
            .on(
                "postgres_changes",
                { event: "*", schema: "public", table: "pass_attempt_votes", filter: `attempt_id=eq.${currentAttemptId}` },
                () => void load()
            )
            .subscribe();

        return () => {
            void supabase.removeChannel(channel);
        };
    }, [supabase, lobbyId, currentAttemptId, load]);

    return { attempt, myVote, refresh: load };
}
