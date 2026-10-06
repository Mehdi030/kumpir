"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type FriendStatus = {
    userId: string;
    username: string;
    displayName: string | null;
    avatarEmoji: string | null;
    avatarColor: string | null;
    online: boolean;
    lastSeen: string | null;
    lobbyCode: string | null;
    lobbyPhase: string | null;
    joinable: boolean;
};

const REFRESH_MS = 30000;

/** Meine Freunde mit Online-Status (Migration 086). Aktualisiert sich alle 30 s, solange der Tab sichtbar ist. */
export function useFriendsStatus(userId: string | null | undefined) {
    const [friends, setFriends] = useState<FriendStatus[] | null>(null);
    const [error, setError] = useState(false);

    const load = useCallback(async () => {
        if (!userId) return;
        const { data, error: err } = await getSupabaseClient().rpc("get_friends_status");
        if (err) {
            setError(true);
            return;
        }
        setError(false);
        setFriends((data ?? []) as FriendStatus[]);
    }, [userId]);

    useEffect(() => {
        if (!userId) return;
        const run = () => {
            if (document.visibilityState !== "hidden") void load();
        };
        const first = window.setTimeout(() => void load(), 0); // erstes Laden immer; danach nur, solange der Tab sichtbar ist
        const t = window.setInterval(run, REFRESH_MS);
        document.addEventListener("visibilitychange", run);
        return () => {
            window.clearTimeout(first);
            window.clearInterval(t);
            document.removeEventListener("visibilitychange", run);
        };
    }, [userId, load]);

    return { friends: userId ? (friends ?? []) : [], loading: !!userId && friends === null && !error, error, refresh: load };
}
