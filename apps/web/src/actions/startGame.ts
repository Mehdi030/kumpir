"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";

export type StartGameResult = { ok: true } | { ok: false; error: string };

export async function startGame(code: string, mePlayerId: string): Promise<StartGameResult> {
    try {
        const supabase = await createSupabaseServerClient();

        // Resolve lobby_id from code (robust across RPC signatures)
        const { data: lobby, error: lobbyErr } = await supabase
            .from("lobbies")
            .select("id")
            .eq("code", code)
            .maybeSingle();

        if (lobbyErr || !lobby?.id) {
            return { ok: false, error: lobbyErr?.message ?? "Lobby nicht gefunden." };
        }

        // Use the RPC that matches your DB function list: rpc_start_game(p_lobby_id uuid, p_player_id uuid)
        const { error } = await supabase.rpc("rpc_start_game", {
            p_lobby_id: lobby.id,
            p_player_id: mePlayerId,
        });

        if (error) return { ok: false, error: error.message };
        return { ok: true };
    } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : "Unbekannter Fehler";
        return { ok: false, error: msg };
    }
}