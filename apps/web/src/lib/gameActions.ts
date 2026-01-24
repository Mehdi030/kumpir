// @/lib/gameActions.ts
import { getSupabaseClient } from "./supabaseClient";

/** ===== Types (minimal) ===== */

export type LobbyStatus = "lobby" | "in_game" | "ended";

export type Lobby = {
    id: string;
    code: string;
    status: LobbyStatus;
    current_holder_player_id: string | null;
};

/** ===== Client ===== */

function supabase() {
    return getSupabaseClient();
}

/** ===== Actions ===== */

export async function passPotato(
    lobbyId: string,
    fromPlayerId: string,
    toPlayerId: string
): Promise<void> {
    const { error } = await supabase().rpc("rpc_pass_potato", {
        p_lobby_id: lobbyId,
        p_from_player_id: fromPlayerId,
        p_to_player_id: toPlayerId,
    });

    if (error) {
        throw new Error(error.message);
    }
}

export async function explodePotato(
    lobbyId: string,
    playerId: string
): Promise<void> {
    const { error } = await supabase().rpc("rpc_explode_potato", {
        p_lobby_id: lobbyId,
        p_player_id: playerId,
    });

    if (error) {
        throw new Error(error.message);
    }
}

export async function fetchLobby(lobbyId: string): Promise<Lobby | null> {
    const { data, error } = await supabase()
        .from("lobbies")
        .select("id, code, status, current_holder_player_id")
        .eq("id", lobbyId)
        .single();

    if (error || !data) return null;
    return data as Lobby;
}
