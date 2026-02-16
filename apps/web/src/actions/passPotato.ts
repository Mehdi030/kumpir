"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";

export type PassPotatoResult =
    | { ok: true }
    | { ok: false; error: string };

export async function passPotato(code: string, playerId: string): Promise<PassPotatoResult> {
    try {
        const supabase = await createSupabaseServerClient();

        const { data: lobby, error: lobbyErr } = await supabase
            .from("lobbies")
            .select("id, phase, holder_player_id")
            .eq("code", code)
            .single();

        if (lobbyErr || !lobby) return { ok: false, error: "Lobby nicht gefunden." };
        if (lobby.phase !== "running") return { ok: false, error: "Spiel läuft nicht." };
        if (lobby.holder_player_id !== playerId) return { ok: false, error: "Du hältst die Kartoffel nicht." };

        const { data: alive, error: aliveErr } = await supabase
            .from("players")
            .select("player_id, seat_index")
            .eq("lobby_id", lobby.id)
            .eq("is_alive", true)
            .order("seat_index", { ascending: true });

        if (aliveErr || !alive || alive.length < 2) return { ok: false, error: "Nicht genug Spieler." };

        const idx = alive.findIndex((p) => p.player_id === playerId);
        if (idx === -1) return { ok: false, error: "Spieler nicht in Lobby." };

        const next = alive[(idx + 1) % alive.length].player_id;

        const { error: updErr } = await supabase
            .from("lobbies")
            .update({ holder_player_id: next, last_activity_at: new Date().toISOString() })
            .eq("id", lobby.id);

        if (updErr) return { ok: false, error: "Weitergabe fehlgeschlagen." };

        return { ok: true };
    } catch (e: unknown) {
        return { ok: false, error: e instanceof Error ? e.message : "Unbekannter Fehler" };
    }
}