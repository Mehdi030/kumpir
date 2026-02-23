"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";

type Ok = { ok: true };
type Err = { ok: false; error: string };
type Res = Ok | Err;

function toErr(e: unknown): Err {
    const msg = e instanceof Error ? e.message : typeof e === "string" ? e : "Unknown error";
    return { ok: false, error: msg };
}

/**
 * Passiert die Kartoffel an den NEXT Spieler (DB berechnet Next).
 * DB RPC Signatur: rpc_pass_potato(p_code text, p_player_id uuid)
 */
export async function passPotatoAction(args: { code: string; playerId: string }): Promise<Res> {
    try {
        const supabase = await createSupabaseServerClient();

        const { error } = await supabase.rpc("rpc_pass_potato", {
            p_code: args.code,
            p_player_id: args.playerId,
        });

        if (error) return { ok: false, error: error.message };
        return { ok: true };
    } catch (e) {
        return toErr(e);
    }
}

/**
 * Tick-Game (Explosion wenn fällig).
 * DB RPC Signatur: rpc_tick_game(p_code text)
 */
export async function tickGameAction(args: { code: string }): Promise<Res> {
    try {
        const supabase = await createSupabaseServerClient();

        const { error } = await supabase.rpc("rpc_tick_game", {
            p_code: args.code,
        });

        if (error) return { ok: false, error: error.message };
        return { ok: true };
    } catch (e) {
        return toErr(e);
    }
}