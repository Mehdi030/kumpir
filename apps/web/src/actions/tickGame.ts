// actions/tickGame.ts (nur der running/due Teil relevant)

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

    const loserId = lobby.holder_player_id;
    if (!loserId) return { ok: true, didWork: false };

    // ✅ CLAIM: nur 1 Tick darf weiterlaufen
    const { data: claimRow, error: claimErr } = await supabase
        .from("lobbies")
        .update({
            explode_at: null, // 🔒 LOCK
            last_activity_at: new Date().toISOString(),
        })
        .eq("id", lobby.id)
        .eq("phase", "running")
        .eq("explode_at", lobby.explode_at)     // ✅ CAS
        .eq("holder_player_id", loserId)        // ✅ CAS
        .select("id")
        .maybeSingle();

    if (claimErr) throw new Error(`Tick-Claim fehlgeschlagen: ${claimErr.message}`);
    if (!claimRow) return { ok: true, didWork: false }; // jemand anders war schneller

    // Ab hier: wir sind der einzige Tick-Prozessor

    const { data: alive, error: aliveErr } = await supabase
        .from("players")
        .select("player_id, seat_index")
        .eq("lobby_id", lobby.id)
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (aliveErr || !alive) throw new Error(`Spieler konnten nicht geladen werden: ${aliveErr?.message ?? ""}`);

    if (alive.length <= 1) {
        const { error: finErr } = await supabase
            .from("lobbies")
            .update({ phase: "finished", last_activity_at: new Date().toISOString() })
            .eq("id", lobby.id)
            .eq("phase", "running")
            .is("explode_at", null) // ✅ nur wenn wir gelockt haben
            .select("id")
            .maybeSingle();

        if (finErr) throw new Error(`Finish fehlgeschlagen: ${finErr.message}`);
        return { ok: true, didWork: true, finished: true };
    }

    // Holder muss alive sein
    const holderIsAlive = alive.some((p) => p.player_id === loserId);
    if (!holderIsAlive) return { ok: true, didWork: false };

    // ✅ erst jetzt killen (nach Claim)
    const { error: killErr } = await supabase
        .from("players")
        .update({ is_alive: false })
        .eq("lobby_id", lobby.id)
        .eq("player_id", loserId)
        .eq("is_alive", true);

    if (killErr) throw new Error(`Elimination fehlgeschlagen: ${killErr.message}`);

    const { data: aliveAfter, error: afterErr } = await supabase
        .from("players")
        .select("player_id, seat_index")
        .eq("lobby_id", lobby.id)
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (afterErr || !aliveAfter) throw new Error(`Spieler konnten nicht geladen werden: ${afterErr?.message ?? ""}`);

    if (aliveAfter.length === 1) {
        const { data: finRow, error: updErr } = await supabase
            .from("lobbies")
            .update({
                phase: "finished",
                holder_player_id: aliveAfter[0].player_id,
                last_loser_player_id: loserId,
                last_activity_at: new Date().toISOString(),
            })
            .eq("id", lobby.id)
            .eq("phase", "running")
            .is("explode_at", null)              // ✅ unser Lock
            .eq("holder_player_id", loserId)     // ✅ sollte unverändert sein, da passPotato jetzt blockt
            .select("id")
            .maybeSingle();

        if (updErr) throw new Error(`Finish fehlgeschlagen: ${updErr.message}`);
        if (!finRow) return { ok: true, didWork: false };
        return { ok: true, didWork: true, finished: true };
    }

    const loserSeat = alive.find((p) => p.player_id === loserId)?.seat_index ?? -1;
    const next = aliveAfter.find((p) => (p.seat_index ?? 0) > loserSeat) ?? aliveAfter[0];
    const nextHolderId = next.player_id;

    const speed = (lobby.round_speed ?? "normal") as RoundSpeed;
    const explodeInSec = calculateExplodeSeconds(speed, aliveAfter.length, {
        exponent: 1.9,
        quantizeStepSec: 0.5,
        clampMinSec: 3,
    });

    const newExplodeAt = new Date(Date.now() + explodeInSec * 1000).toISOString();
    const newRoundNumber = (lobby.round_number ?? 1) + 1;

    const { data: updRow, error: updErr } = await supabase
        .from("lobbies")
        .update({
            holder_player_id: nextHolderId,
            explode_at: newExplodeAt,           // 🔓 unlock + new timer
            round_number: newRoundNumber,
            last_loser_player_id: loserId,
            last_activity_at: new Date().toISOString(),
        })
        .eq("id", lobby.id)
        .eq("phase", "running")
        .is("explode_at", null)              // ✅ nur der Claimer darf weitermachen
        .eq("holder_player_id", loserId)     // ✅
        .select("id")
        .maybeSingle();

    if (updErr) throw new Error(`Rundenstart fehlgeschlagen: ${updErr.message}`);
    if (!updRow) return { ok: true, didWork: false };

    return { ok: true, didWork: true, finished: false };
}