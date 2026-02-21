"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";

export type StartGameResult = { ok: true } | { ok: false; error: string };

export async function startGame(code: string, mePlayerId: string): Promise<StartGameResult> {
    try {
        const supabase = await createSupabaseServerClient();

        const { data: lobby, error: lobbyErr } = await supabase
            .from("lobbies")
            .select("id")
            .eq("code", code)
            .maybeSingle();

        if (lobbyErr || !lobby?.id) return { ok: false, error: lobbyErr?.message ?? "Lobby nicht gefunden." };

        const { error } = await supabase.rpc("rpc_begin_topic_vote", {
            p_lobby_id: lobby.id,
            p_player_id: mePlayerId,
        });

        if (error) return { ok: false, error: error.message };
        return { ok: true };
    } catch (e: unknown) {
        return { ok: false, error: e instanceof Error ? e.message : "Unbekannter Fehler" };
    }
}