import { getSupabaseClient } from "./supabaseClient";
import { requireAuthUserId } from "./user";

function supabase() {
    return getSupabaseClient();
}

export async function passPotato(lobbyId: string, toPlayerId: string) {
    const fromPlayerId = await requireAuthUserId(); // ✅ immer UUID
    const { error } = await supabase().rpc("rpc_pass_potato", {
        p_lobby_id: lobbyId,
        p_from_player_id: fromPlayerId,
        p_to_player_id: toPlayerId, // muss ebenfalls UUID sein (aus lobby_players.player_id)
    });
    if (error) throw new Error(error.message);
}

export async function explodePotato(lobbyId: string) {
    const playerId = await requireAuthUserId(); // ✅ immer UUID
    const { error } = await supabase().rpc("rpc_explode_potato", {
        p_lobby_id: lobbyId,
        p_player_id: playerId,
    });
    if (error) throw new Error(error.message);
}
