// @/lib/gameActions.ts
import { supabase } from "./supabaseClient";

/** ===== Types (minimal) ===== */
export type LobbyStatus = "lobby" | "in_game" | "ended";

export type Lobby = {
    code: string;
    host_name: string | null;
    status: LobbyStatus;
    created_at: string;
    started_at: string | null;
    ended_at: string | null;
    last_activity_at: string | null;
};

export type Player = {
    id: string;
    lobby_code: string;
    name: string;
    is_ready: boolean;
    is_connected: boolean;
    joined_at: string;
    last_seen_at: string | null;
    is_eliminated?: boolean;
    eliminated_at?: string | null;
};

export type GameState = {
    lobby_code: string;
    round: number;
    state: string; // e.g. "idle" | "playing" | "ended"
    current_holder_player_id: string | null;
    timer_ends_at: string | null;
    created_at: string;
    updated_at: string;
};

function assertOk<T>(data: T | null, error: any, context: string): T {
    if (error) throw new Error(`${context}: ${error.message ?? String(error)}`);
    if (data === null) throw new Error(`${context}: No data returned`);
    return data;
}

/** ===== Read helpers ===== */
export async function getLobby(code: string): Promise<Lobby | null> {
    const { data, error } = await supabase
        .from("lobbies")
        .select("*")
        .eq("code", code.trim())
        .maybeSingle();

    if (error) throw new Error(`getLobby: ${error.message}`);
    return data as Lobby | null;
}

export async function getPlayers(code: string): Promise<Player[]> {
    const { data, error } = await supabase
        .from("players")
        .select("*")
        .eq("lobby_code", code.trim())
        .order("joined_at", { ascending: true });

    return assertOk<Player[]>(data as any, error, "getPlayers");
}

export async function getGameState(code: string): Promise<GameState | null> {
    const { data, error } = await supabase
        .from("game_state")
        .select("*")
        .eq("lobby_code", code.trim())
        .maybeSingle();

    if (error) throw new Error(`getGameState: ${error.message}`);
    return data as GameState | null;
}

/** ===== Write helpers (tables) ===== */

/**
 * Optional helper: Lobby direkt erstellen (solange ihr dafür noch keine RPC habt).
 * Du kannst das später durch create_lobby() ersetzen.
 */
export async function createLobby(params: { code: string; hostName?: string }): Promise<Lobby> {
    const code = params.code.trim();
    const host_name = params.hostName ?? null;

    const { data, error } = await supabase
        .from("lobbies")
        .insert({
            code,
            host_name,
            status: "lobby",
            last_activity_at: new Date().toISOString(),
        })
        .select("*")
        .single();

    return assertOk<Lobby>(data as any, error, "createLobby");
}

export async function joinLobby(params: { code: string; name: string }): Promise<Player> {
    const lobby_code = params.code.trim();
    const name = params.name.trim();

    const { data, error } = await supabase
        .from("players")
        .insert({
            id: crypto.randomUUID(),
            lobby_code,
            name,
            is_ready: false,
            is_connected: true,
            joined_at: new Date().toISOString(),
            last_seen_at: new Date().toISOString(),
        })
        .select("*")
        .single();

    return assertOk<Player>(data as any, error, "joinLobby");
}

export async function setReady(params: { playerId: string; ready: boolean }): Promise<void> {
    const { error } = await supabase
        .from("players")
        .update({
            is_ready: params.ready,
            last_seen_at: new Date().toISOString(),
        })
        .eq("id", params.playerId);

    if (error) throw new Error(`setReady: ${error.message}`);
}

export async function setConnected(params: { playerId: string; connected: boolean }): Promise<void> {
    const { error } = await supabase
        .from("players")
        .update({
            is_connected: params.connected,
            last_seen_at: new Date().toISOString(),
        })
        .eq("id", params.playerId);

    if (error) throw new Error(`setConnected: ${error.message}`);
}

/** ===== RPC actions (game loop) ===== */

export async function startLobby(code: string): Promise<void> {
    const { error } = await supabase.rpc("start_lobby", { p_code: code.trim() });
    if (error) throw new Error(`startLobby: ${error.message}`);
}

export async function beginRound(code: string, seconds = 15): Promise<void> {
    const { error } = await supabase.rpc("begin_round", {
        p_code: code.trim(),
        p_seconds: seconds,
    });
    if (error) throw new Error(`beginRound: ${error.message}`);
}

export async function passPotato(code: string, toPlayerId: string, seconds = 15): Promise<void> {
    const { error } = await supabase.rpc("pass_potato", {
        p_code: code.trim(),
        p_to_player_id: toPlayerId,
        p_seconds: seconds,
    });
    if (error) throw new Error(`passPotato: ${error.message}`);
}

export async function boom(code: string, seconds = 15): Promise<void> {
    const { error } = await supabase.rpc("boom", {
        p_code: code.trim(),
        p_seconds: seconds,
    });
    if (error) throw new Error(`boom: ${error.message}`);
}

export async function endLobby(code: string): Promise<void> {
    const { error } = await supabase.rpc("end_lobby", { p_code: code.trim() });
    if (error) throw new Error(`endLobby: ${error.message}`);
}

export async function resetLobby(code: string): Promise<void> {
    const { error } = await supabase.rpc("reset_lobby", { p_code: code.trim() });
    if (error) throw new Error(`resetLobby: ${error.message}`);
}
