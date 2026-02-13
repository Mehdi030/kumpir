"use server";

import { createSupabaseServerClient } from "@/lib/supabaseServer";
import { ROUND_SPEEDS } from "@/lib/gameConfig";

export async function startGame(code: string) {
    const supabase = await createSupabaseServerClient();

    const { data: lobby, error: lobbyErr } = await supabase
        .from("lobbies")
        .select("id, code, phase, round_speed")
        .eq("code", code)
        .single();

    if (lobbyErr || !lobby) throw new Error("Lobby nicht gefunden.");

    if (lobby.phase === "running") return { ok: true, alreadyRunning: true };
    if (lobby.phase === "finished") throw new Error("Spiel ist bereits beendet.");

    // Alive-Spieler laden (ordered)
    const { data: alive, error: aliveErr } = await supabase
        .from("players")
        .select("player_id, seat_index, ready, is_alive")
        .eq("lobby_id", lobby.id)
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (aliveErr || !alive) throw new Error("Spieler konnten nicht geladen werden.");
    if (alive.length < 2) throw new Error("Mindestens 2 Spieler nötig.");
    if (!alive.every((p) => !!p.ready)) throw new Error("Nicht alle Spieler sind bereit.");

    // Start-Holder random
    const startHolder = alive[Math.floor(Math.random() * alive.length)].player_id;

    // explode_at setzen (wie in tickGame)
    const speedKey = ((lobby.round_speed ?? "normal") as keyof typeof ROUND_SPEEDS);
    const [baseMin, baseMax] = ROUND_SPEEDS[speedKey].explodeRangeSec;

    const n = alive.length;
    const scale = clamp(0.75, 1.25, 1.15 - n * 0.035);
    const minSec = Math.max(3, baseMin * scale);
    const maxSec = Math.max(minSec + 1, baseMax * scale);
    const explodeInSec = biasedRandom(minSec, maxSec, 1.9);

    const explodeAt = new Date(Date.now() + explodeInSec * 1000).toISOString();

    // Lobby starten
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

    if (updErr) throw new Error("Start fehlgeschlagen.");

    // optional: Ready resetten (empfohlen)
    await supabase
        .from("players")
        .update({ ready: false })
        .eq("lobby_id", lobby.id);

    return { ok: true };
}

function clamp(min: number, max: number, v: number) {
    return Math.max(min, Math.min(max, v));
}
function biasedRandom(min: number, max: number, exponent = 1.0) {
    const u = Math.random();
    const biased = Math.pow(u, exponent);
    return min + biased * (max - min);
}
