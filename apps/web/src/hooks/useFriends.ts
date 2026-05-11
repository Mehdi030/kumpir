"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type FriendRow = {
    user_id: string;
    friend_user_id: string;
    friend_username: string;
    status: "pending" | "accepted" | "blocked";
    created_at: string;
    accepted_at: string | null;
};

type Result = {
    accepted: FriendRow[];
    outgoing: FriendRow[]; // ich habe angefragt, wartet auf accept
    incoming: FriendRow[]; // jemand hat MICH angefragt
    loading: boolean;
    error: string;
    refresh: () => Promise<void>;
    sendRequest: (toUsername: string) => Promise<string | null>;
    acceptRequest: (fromUserId: string) => Promise<string | null>;
    removeFriend: (friendUserId: string) => Promise<string | null>;
};

export function useFriends(userId: string | null | undefined): Result {
    const supabase = getSupabaseClient();
    const [accepted, setAccepted] = useState<FriendRow[]>([]);
    const [outgoing, setOutgoing] = useState<FriendRow[]>([]);
    const [incoming, setIncoming] = useState<FriendRow[]>([]);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        if (!userId) {
            setAccepted([]); setOutgoing([]); setIncoming([]);
            return;
        }
        setError(""); setLoading(true);
        try {
            // accepted + outgoing pending (ich → andere)
            const myRes = await supabase
                .from("friends_view")
                .select("*")
                .eq("user_id", userId);

            if (myRes.error) { setError(myRes.error.message); return; }
            const myRows = (myRes.data ?? []) as FriendRow[];
            setAccepted(myRows.filter((r) => r.status === "accepted"));
            setOutgoing(myRows.filter((r) => r.status === "pending"));

            // incoming: jemand hat MICH (= friend_user_id) angefragt, status=pending
            const incRes = await supabase
                .from("friendships")
                .select("user_id,friend_user_id,status,created_at,accepted_at")
                .eq("friend_user_id", userId)
                .eq("status", "pending");

            if (incRes.error) { setError(incRes.error.message); return; }
            const incRaw = (incRes.data ?? []) as Array<{ user_id: string; friend_user_id: string; status: string; created_at: string; accepted_at: string | null }>;

            // Username für die Anfragenden holen
            if (incRaw.length > 0) {
                const fromIds = incRaw.map((r) => r.user_id);
                const profRes = await supabase
                    .from("profiles")
                    .select("id,username")
                    .in("id", fromIds);
                const profMap = new Map((profRes.data ?? []).map((p: { id: string; username: string }) => [p.id, p.username]));
                setIncoming(incRaw.map((r) => ({
                    user_id: r.user_id,
                    friend_user_id: r.friend_user_id,
                    friend_username: profMap.get(r.user_id) ?? "—",
                    status: r.status as FriendRow["status"],
                    created_at: r.created_at,
                    accepted_at: r.accepted_at,
                })));
            } else {
                setIncoming([]);
            }
        } finally {
            setLoading(false);
        }
    }, [supabase, userId]);

    useEffect(() => { void load(); }, [load]);

    const sendRequest = useCallback(async (toUsername: string): Promise<string | null> => {
        if (!userId) return "Nicht eingeloggt.";
        const { error: e } = await supabase.rpc("rpc_send_friend_request", {
            p_from_user_id: userId,
            p_to_username: toUsername,
        });
        if (e) return e.message;
        await load();
        return null;
    }, [supabase, userId, load]);

    const acceptRequest = useCallback(async (fromUserId: string): Promise<string | null> => {
        if (!userId) return "Nicht eingeloggt.";
        const { error: e } = await supabase.rpc("rpc_accept_friend_request", {
            p_me_user_id: userId,
            p_from_user_id: fromUserId,
        });
        if (e) return e.message;
        await load();
        return null;
    }, [supabase, userId, load]);

    const removeFriend = useCallback(async (friendUserId: string): Promise<string | null> => {
        if (!userId) return "Nicht eingeloggt.";
        const { error: e } = await supabase.rpc("rpc_remove_friend", {
            p_me_user_id: userId,
            p_friend_user_id: friendUserId,
        });
        if (e) return e.message;
        await load();
        return null;
    }, [supabase, userId, load]);

    return { accepted, outgoing, incoming, loading, error, refresh: load, sendRequest, acceptRequest, removeFriend };
}
