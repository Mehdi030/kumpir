// actions/passPotato.ts
"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";

export type PassPotatoResult = { ok: true } | { ok: false; error: string };

export async function passPotato(code: string, playerId: string): Promise<PassPotatoResult> {
    try {
        const supabase = await createSupabaseServerClient();

        const { data: lobby, error: lobbyErr } = await supabase
            .from("lobbies")
            .select("id, phase, holder_player_id, explode_at")
            .eq("code", code)
            .single();

        if (lobbyErr || !lobby) return { ok: false, error: lobbyErr?.message ?? "Lobby nicht gefunden." };
        if (lobby.phase !== "running") return { ok: false, error: "Spiel läuft nicht." };
        if (lobby.holder_player_id !== playerId) return { ok: false, error: "Du hältst die Kartoffel nicht." };

        // 🔒 Pass blocken, wenn Timer schon fällig ist oder gerade getickt wird (tickGame claim setzt explode_at = null)
        if (!lobby.explode_at) return { ok: false, error: "Zu spät (Timer wird gerade verarbeitet)." };

        const explodeMs = Date.parse(lobby.explode_at);
        if (Number.isNaN(explodeMs)) return { ok: false, error: "Ungültiger Timer." };

        // kleine Grace, damit es nicht “unfair” flackert
        if (Date.now() >= explodeMs - 150) return { ok: false, error: "Zu spät (Timer abgelaufen)." };

        const { data: alive, error: aliveErr } = await supabase
            .from("players")
            .select("player_id, seat_index, status, is_alive")
            .eq("lobby_id", lobby.id)
            .eq("status", "active")
            .eq("is_alive", true)
            .order("seat_index", { ascending: true });

        if (aliveErr) return { ok: false, error: aliveErr.message };
        if (!alive || alive.length < 2) return { ok: false, error: "Nicht genug Spieler." };

        const idx = alive.findIndex((p) => p.player_id === playerId);
        if (idx === -1) return { ok: false, error: "Spieler nicht in Lobby." };

        const next = alive[(idx + 1) % alive.length].player_id;

        const { data: updData, error: updErr } = await supabase
            .from("lobbies")
            .update({
                holder_player_id: next,
                last_activity_at: new Date().toISOString(),
            })
            .eq("id", lobby.id)
            .eq("holder_player_id", playerId) // ✅ CAS gegen Double-Click / Race
            .eq("explode_at", lobby.explode_at) // ✅ CAS auch auf Timer (blockt bei claim/expiry)
            .select("id");

        if (updErr) return { ok: false, error: updErr.message };
        if (!updData || updData.length === 0) return { ok: false, error: "Weitergabe nicht übernommen (Zustand hat sich geändert)." };

        return { ok: true };
    } catch (e: unknown) {
        return { ok: false, error: e instanceof Error ? e.message : "Unbekannter Fehler" };
    }
}