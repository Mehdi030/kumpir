"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export type SavedLobby = {
    user_id: string;
    lobby_code: string;
    nickname: string;
    last_used: string;
    created_at: string;
};

export function useSavedLobbies(userId: string | null | undefined) {
    const supabase = getSupabaseClient();
    const [rows, setRows] = useState<SavedLobby[]>([]);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        if (!userId) { setRows([]); return; }
        setError(""); setLoading(true);
        try {
            const res = await supabase
                .from("saved_lobbies")
                .select("*")
                .eq("user_id", userId)
                .order("last_used", { ascending: false });
            if (res.error) { setError(res.error.message); return; }
            setRows((res.data ?? []) as SavedLobby[]);
        } finally {
            setLoading(false);
        }
    }, [supabase, userId]);

    useEffect(() => { void load(); }, [load]);

    const save = useCallback(async (code: string, nickname: string) => {
        if (!userId) return "Nicht eingeloggt.";
        const { error: e } = await supabase.rpc("rpc_save_lobby", {
            p_user_id: userId,
            p_lobby_code: code,
            p_nickname: nickname,
        });
        if (e) return e.message;
        await load();
        return null;
    }, [supabase, userId, load]);

    const unsave = useCallback(async (code: string) => {
        if (!userId) return "Nicht eingeloggt.";
        const { error: e } = await supabase.rpc("rpc_unsave_lobby", {
            p_user_id: userId,
            p_lobby_code: code,
        });
        if (e) return e.message;
        await load();
        return null;
    }, [supabase, userId, load]);

    return { rows, loading, error, save, unsave, refresh: load };
}
