"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";
import { calculateExplodeSeconds, type RoundSpeed } from "@/lib/gameConfig";

export type PassPotatoResult = { ok: true };

function getErrorMessage(e: unknown): string {
    if (e instanceof Error) return e.message;
    if (typeof e === "string") return e;
    try {
        return JSON.stringify(e);
    } catch {
        return "Unbekannter Fehler";
    }
}

/**
 * Important: This action THROWS on failure.
 * Your GamePage uses try/catch + getErrorMessage(e) → that expects thrown errors.
 */
export async function passPotato(code: string, playerId: string): Promise<PassPotatoResult> {
    try {
        const supabase = await createSupabaseServerClient();

        const { data: lobby, error: lobbyErr } = await supabase
            .from("lobbies")
            .select("id, phase, holder_player_id, round_speed")
            .eq("code", code)
            .maybeSingle();

        if (lobbyErr || !lobby) throw new Error("Lobby nicht gefunden.");
        if (lobby.phase !== "running") throw new Error("Spiel läuft nicht.");
        if (lobby.holder_player_id !== playerId) throw new Error("Du hältst die Kartoffel nicht.");

        const { data: alive, error: aliveErr } = await supabase
            .from("players")
            .select("player_id, seat_index")
            .eq("lobby_id", lobby.id)
            .eq("is_alive", true)
            .order("seat_index", { ascending: true });

        if (aliveErr || !alive) throw new Error(aliveErr?.message ?? "Spieler konnten nicht geladen werden.");
        if (alive.length < 2) throw new Error("Nicht genug Spieler.");

        const idx = alive.findIndex((p) => p.player_id === playerId);
        if (idx === -1) throw new Error("Spieler nicht in Lobby.");

        const nextHolderId = alive[(idx + 1) % alive.length].player_id;

        // Reset explode timer on every pass (critical!)
        const speed = ((lobby.round_speed ?? "normal") as RoundSpeed) ?? "normal";
        const explodeInSec = calculateExplodeSeconds(speed, alive.length, {
            exponent: 1.9,
            quantizeStepSec: 0.5,
            clampMinSec: 3,
        });

        const newExplodeAt = new Date(Date.now() + explodeInSec * 1000).toISOString();

        // CAS update: only succeeds if you STILL are the holder (prevents double pass / lag)
        const { data: updRow, error: updErr } = await supabase
            .from("lobbies")
            .update({
                holder_player_id: nextHolderId,
                explode_at: newExplodeAt,
                last_activity_at: new Date().toISOString(),
            })
            .eq("id", lobby.id)
            .eq("phase", "running")
            .eq("holder_player_id", playerId)
            .select("id")
            .maybeSingle();

        if (updErr) throw new Error(updErr.message);
        if (!updRow) throw new Error("Zu spät: Kartoffel wurde bereits weitergegeben.");

        return { ok: true };
    } catch (e: unknown) {
        // throw so GamePage catch() shows it reliably
        throw new Error(getErrorMessage(e));
    }
}