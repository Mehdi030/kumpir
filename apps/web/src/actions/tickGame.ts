"use server";

import { createSupabaseAdminClient } from "@/lib/supabaseAdmin";
import { calculateExplodeSeconds, type RoundSpeed } from "@/lib/gameConfig";

export async function tickGame(code: string) {
    const supabase = createSupabaseAdminClient();

    const { data: lobby, error: lobbyErr } = await supabase
        .from("lobbies")
        .select("id, phase, holder_player_id, explode_at, round_speed, round_number")
        .eq("code", code)
        .single();

    if (lobbyErr || !lobby) throw new Error(`Lobby nicht gefunden: ${lobbyErr?.message ?? ""}`);
    if (lobby.phase !== "running") return { ok: true, didWork: false };
    if (!lobby.explode_at) return { ok: true, didWork: false };

    const nowMs = Date.now();
    const explodeMs = new Date(lobby.explode_at).getTime();
    if (Number.isNaN(explodeMs)) return { ok: true, didWork: false };
    if (nowMs < explodeMs) return { ok: true, didWork: false };

    // Alive vor der Elimination
    const { data: alive, error: aliveErr } = await supabase
        .from("players")
        .select("player_id, seat_index")
        .eq("lobby_id", lobby.id)
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (aliveErr || !alive) throw new Error(`Spieler konnten nicht geladen werden: ${aliveErr?.message ?? ""}`);

    // Wenn schon fertig
    if (alive.length <= 1) {
        const { error: finErr } = await supabase
            .from("lobbies")
            .update({
                phase: "finished",
                last_activity_at: new Date().toISOString(),
            })
            .eq("id", lobby.id);

        if (finErr) throw new Error(`Finish fehlgeschlagen: ${finErr.message}`);
        return { ok: true, didWork: true, finished: true };
    }

    const loserId = lobby.holder_player_id;
    if (!loserId) return { ok: true, didWork: false };

    // Holder muss alive sein
    const holderIsAlive = alive.some((p) => p.player_id === loserId);
    if (!holderIsAlive) return { ok: true, didWork: false };

    // Holder eliminieren
    const { error: killErr } = await supabase
        .from("players")
        .update({ is_alive: false })
        .eq("lobby_id", lobby.id)
        .eq("player_id", loserId);

    if (killErr) throw new Error(`Elimination fehlgeschlagen: ${killErr.message}`);

    // Alive nach der Elimination
    const { data: aliveAfter, error: afterErr } = await supabase
        .from("players")
        .select("player_id, seat_index")
        .eq("lobby_id", lobby.id)
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (afterErr || !aliveAfter) throw new Error(`Spieler konnten nicht geladen werden: ${afterErr?.message ?? ""}`);

    // Wenn jetzt nur noch 1 übrig: Spiel beenden + Winner setzen
    if (aliveAfter.length === 1) {
        const { error: updErr } = await supabase
            .from("lobbies")
            .update({
                phase: "finished",
                holder_player_id: aliveAfter[0].player_id, // Winner als Holder
                last_loser_player_id: loserId,
                last_activity_at: new Date().toISOString(),
            })
            .eq("id", lobby.id);

        if (updErr) throw new Error(`Finish fehlgeschlagen: ${updErr.message}`);

        return { ok: true, didWork: true, finished: true };
    }

    // Next holder (Seat-Reihenfolge, wrap-around)
    const loserSeat = alive.find((p) => p.player_id === loserId)?.seat_index ?? -1;
    const next =
        aliveAfter.find((p) => (p.seat_index ?? 0) > loserSeat) ?? aliveAfter[0];

    const nextHolderId = next.player_id;

    // Neue explode_at berechnen
    const speed = (lobby.round_speed ?? "normal") as RoundSpeed;
    const explodeInSec = calculateExplodeSeconds(speed, aliveAfter.length, {
        exponent: 1.9,
        quantizeStepSec: 0.5,
        clampMinSec: 3,
    });

    const newExplodeAt = new Date(Date.now() + explodeInSec * 1000).toISOString();
    const newRoundNumber = (lobby.round_number ?? 1) + 1;

    // Lobby updaten
    const { error: updErr } = await supabase
        .from("lobbies")
        .update({
            holder_player_id: nextHolderId,
            explode_at: newExplodeAt,
            round_number: newRoundNumber,
            last_loser_player_id: loserId,
            last_activity_at: new Date().toISOString(),
        })
        .eq("id", lobby.id);

    if (updErr) throw new Error(`Rundenstart fehlgeschlagen: ${updErr.message}`);

    return { ok: true, didWork: true, finished: false };
}