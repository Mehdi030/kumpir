"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";

export type StartGameResult = { ok: true } | { ok: false; error: string };

export async function startGame(code: string, mePlayerId: string): Promise<StartGameResult> {
    try {
        const supabase = await createSupabaseServerClient(); // ✅ await

        const { error } = await supabase.rpc("start_game", {
            p_lobby_code: code,
            p_me_player_id: mePlayerId,
        });

        if (error) return { ok: false, error: error.message };
        return { ok: true };
    } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : "Unbekannter Fehler";
        return { ok: false, error: msg };
    }
}