"use server";

// Die RPCs prüfen serverseitig BEIDES: p_me_player_id == lobbies.host_player_id
// UND das Session-Token des Aufrufers (Migration 023/024). Die vom Client
// gelieferte mePlayerId allein reicht also nicht mehr aus -- ohne passendes
// Token lehnt die RPC mit `invalid_session` ab.

import { createSupabaseServerClient } from "@/lib/supabaseServer";

type Ok = { ok: true };
type Err = { ok: false; error: string };
type Res = Ok | Err;

/**
 * Wandelt unknown-Errors in ein sauberes Error-Result um.
 */
function toErr(e: unknown): Err {
    const msg = e instanceof Error ? e.message : typeof e === "string" ? e : "Unknown error";
    return { ok: false, error: msg };
}

/**
 * Kickt einen Spieler aus der Lobby per RPC.
 */
export async function kickPlayerAction(args: {
    lobbyId: string;
    mePlayerId: string;
    targetPlayerId: string;
    sessionToken: string;
}): Promise<Res> {
    try {
        const supabase = await createSupabaseServerClient(args.sessionToken);

        const { error } = await supabase.rpc("kick_player", {
            p_lobby_id: args.lobbyId,
            p_me_player_id: args.mePlayerId,
            p_target_player_id: args.targetPlayerId,
        });

        if (error) return { ok: false, error: error.message };
        return { ok: true };
    } catch (e) {
        return toErr(e);
    }
}

/**
 * Sperrt/entsperrt eine Lobby per RPC.
 */
export async function setLobbyLockAction(args: {
    lobbyId: string;
    mePlayerId: string;
    locked: boolean;
    sessionToken: string;
}): Promise<Res> {
    try {
        const supabase = await createSupabaseServerClient(args.sessionToken);

        const { error } = await supabase.rpc("set_lobby_lock", {
            p_lobby_id: args.lobbyId,
            p_me_player_id: args.mePlayerId,
            p_locked: args.locked,
        });

        if (error) return { ok: false, error: error.message };
        return { ok: true };
    } catch (e) {
        return toErr(e);
    }
}

/**
 * Überträgt die Host-Rolle an einen anderen Spieler per RPC.
 */
export async function transferHostAction(args: {
    lobbyId: string;
    mePlayerId: string;
    newHostPlayerId: string;
    sessionToken: string;
}): Promise<Res> {
    try {
        const supabase = await createSupabaseServerClient(args.sessionToken);

        const { error } = await supabase.rpc("transfer_host", {
            p_lobby_id: args.lobbyId,
            p_me_player_id: args.mePlayerId,
            p_new_host_player_id: args.newHostPlayerId,
        });

        if (error) return { ok: false, error: error.message };
        return { ok: true };
    } catch (e) {
        return toErr(e);
    }
}