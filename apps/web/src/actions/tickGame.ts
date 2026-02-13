"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";
import { ROUND_SPEEDS } from "@/lib/gameConfig";

export async function tickGame(code: string) {
    const supabase = await createSupabaseServerClient();

    const { data: lobby, error: lobbyErr } = await supabase
        .from("lobbies")
        .select("id, phase, holder_player_id, explode_at, round_speed, round_number")
        .eq("code", code)
        .single();

    if (lobbyErr || !lobby) throw new Error("Lobby nicht gefunden.");
    if (lobby.phase !== "running") return { ok: true, didWork: false };
    if (!lobby.explode_at) return { ok: true, didWork: false };

    const nowMs = Date.now();
    const explodeMs = new Date(lobby.explode_at).getTime();
    if (nowMs < explodeMs) return { ok: true, didWork: false };

    const { data: alive, error: aliveErr } = await supabase
        .from("players")
        .select("player_id, seat_index")
        .eq("lobby_id", lobby.id)
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (aliveErr || !alive) throw new Error("Spieler konnten nicht geladen werden.");
    if (alive.length <= 1) {
        await supabase.from("lobbies").update({ phase: "finished" }).eq("id", lobby.id);
        return { ok: true, didWork: true, finished: true };
    }

    const loserId = lobby.holder_player_id;
    if (!loserId) return { ok: true, didWork: false };

    const holderIsAlive = alive.some((p) => p.player_id === loserId);
    if (!holderIsAlive) return { ok: true, didWork: false };

    const { error: killErr } = await supabase
        .from("players")
        .update({ is_alive: false })
        .eq("lobby_id", lobby.id)
        .eq("player_id", loserId);

    if (killErr) throw new Error("Elimination fehlgeschlagen.");

    const { data: aliveAfter, error: afterErr } = await supabase
        .from("players")
        .select("player_id, seat_index")
        .eq("lobby_id", lobby.id)
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (afterErr || !aliveAfter) throw new Error("Spieler konnten nicht geladen werden.");

    if (aliveAfter.length === 1) {
        await supabase
            .from("lobbies")
            .update({
                phase: "finished",
                holder_player_id: aliveAfter[0].player_id,
                last_loser_player_id: loserId,
                last_activity_at: new Date().toISOString(),
            })
            .eq("id", lobby.id);

        return { ok: true, didWork: true, finished: true };
    }

    const loserSeat = alive.find((p) => p.player_id === loserId)?.seat_index ?? 0;
    const next =
        aliveAfter.find((p) => (p.seat_index ?? 0) > loserSeat) ?? aliveAfter[0];

    const nextHolderId = next.player_id;

    const speedKey = ((lobby.round_speed ?? "normal") as keyof typeof ROUND_SPEEDS);
    const [baseMin, baseMax] = ROUND_SPEEDS[speedKey].explodeRangeSec;

    const n = aliveAfter.length;
    const scale = clamp(0.75, 1.25, 1.15 - n * 0.035);
    const minSec = Math.max(3, baseMin * scale);
    const maxSec = Math.max(minSec + 1, baseMax * scale);
    const explodeInSec = biasedRandom(minSec, maxSec, 1.9);

    const explodeAt = new Date(Date.now() + explodeInSec * 1000).toISOString();
    const roundNumber = (lobby.round_number ?? 1) + 1;

    const { error: updErr } = await supabase
        .from("lobbies")
        .update({
            holder_player_id: nextHolderId,
            explode_at: explodeAt,
            round_number: roundNumber,
            last_loser_player_id: loserId,
            last_activity_at: new Date().toISOString(),
        })
        .eq("id", lobby.id);

    if (updErr) throw new Error("Rundenstart fehlgeschlagen.");

    return { ok: true, didWork: true, finished: false };
}

function clamp(min: number, max: number, v: number) {
    return Math.max(min, Math.min(max, v));
}
function biasedRandom(min: number, max: number, exponent = 1.0) {
    const u = Math.random();
    const biased = Math.pow(u, exponent);
    return min + biased * (max - min);
}