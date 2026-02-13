"use server";

import { createSupabaseAdminClient } from "@/lib/supabaseAdmin";
import { calculateExplodeSeconds, type RoundSpeed } from "@/lib/gameConfig";

export async function startGame(code: string) {
    const supabase = createSupabaseAdminClient();

    const { data: lobby, error: lobbyErr } = await supabase
        .from("lobbies")
        .select("id, code, phase, round_speed")
        .eq("code", code)
        .single();

    if (lobbyErr || !lobby) throw new Error("Lobby nicht gefunden.");
    if (lobby.phase === "running") return { ok: true, alreadyRunning: true };
    if (lobby.phase === "finished") throw new Error("Spiel ist bereits beendet.");

    const { data: alive, error: aliveErr } = await supabase
        .from("players")
        .select("player_id, seat_index, ready, is_alive")
        .eq("lobby_id", lobby.id)
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (aliveErr || !alive) throw new Error(`Spieler konnten nicht geladen werden: ${aliveErr?.message ?? ""}`);
    if (alive.length < 1) throw new Error("Mindestens 1 Spieler nötig.");
    if (!alive.every((p) => !!p.ready)) throw new Error("Nicht alle Spieler sind bereit.");

    const startHolder = alive[Math.floor(Math.random() * alive.length)].player_id;

    const speed = (lobby.round_speed ?? "normal") as RoundSpeed;
    const explodeInSec = calculateExplodeSeconds(speed, alive.length, {
        exponent: 1.9,
        quantizeStepSec: 0.5,
        clampMinSec: 3,
    });

    const explodeAt = new Date(Date.now() + explodeInSec * 1000).toISOString();

    const { error: updErr } = await supabase
        .from("lobbies")
        .update({
            phase: "running",
            holder_player_id: startHolder,
            explode_at: explodeAt,
            round_number: 1,
            last_loser_player_id: null,
            last_activity_at: new Date().toISOString(),
        })
        .eq("id", lobby.id);

    if (updErr) throw new Error(`Start fehlgeschlagen: ${updErr.message}`);

    await supabase.from("players").update({ ready: false }).eq("lobby_id", lobby.id);

    return { ok: true };
}