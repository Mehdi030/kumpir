// actions/tickGame.ts
"use server";

import { createSupabaseAdminClient } from "@/lib/supabaseAdmin";
import { calculateExplodeSeconds, type RoundSpeed } from "@/lib/gameConfig";

type TickResult =
    | { ok: true; didWork: boolean; finished?: boolean }
    | { ok: false; error: string };

function computeExplodeAt(speed: RoundSpeed, aliveCount: number) {
    const explodeInSec = calculateExplodeSeconds(speed, aliveCount, {
        exponent: 1.9,
        quantizeStepSec: 0.5,
        clampMinSec: 3,
    });
    return new Date(Date.now() + explodeInSec * 1000).toISOString();
}

export async function tickGame(code: string): Promise<TickResult> {
    const supabase = createSupabaseAdminClient();

    const { data: lobby, error: lobbyErr } = await supabase
        .from("lobbies")
        .select("id, phase, holder_player_id, explode_at, round_speed, round_number")
        .eq("code", code)
        .single();

    if (lobbyErr || !lobby) return { ok: false, error: `Lobby nicht gefunden: ${lobbyErr?.message ?? ""}` };
    if (lobby.phase !== "running") return { ok: true, didWork: false };
    if (!lobby.explode_at) return { ok: true, didWork: false };

    const nowMs = Date.now();
    const explodeMs = new Date(lobby.explode_at).getTime();
    if (Number.isNaN(explodeMs)) return { ok: true, didWork: false };
    if (nowMs < explodeMs) return { ok: true, didWork: false };

    const loserId = lobby.holder_player_id;
    if (!loserId) return { ok: true, didWork: false };

    // ✅ CLAIM / LOCK: nur 1 Tick darf weiterlaufen
    const { data: claimRow, error: claimErr } = await supabase
        .from("lobbies")
        .update({
            explode_at: null, // 🔒 LOCK
            last_activity_at: new Date().toISOString(),
        })
        .eq("id", lobby.id)
        .eq("phase", "running")
        .eq("explode_at", lobby.explode_at) // ✅ CAS
        .eq("holder_player_id", loserId) // ✅ CAS
        .select("id")
        .maybeSingle();

    if (claimErr) return { ok: false, error: `Tick-Claim fehlgeschlagen: ${claimErr.message}` };
    if (!claimRow) return { ok: true, didWork: false }; // jemand anders war schneller

    // Ab hier: wir sind der einzige Tick-Prozessor.
    // Ab hier gilt: KEIN return ohne entweder (a) finished, oder (b) explode_at wieder gesetzt (unlock).

    const { data: alive, error: aliveErr } = await supabase
        .from("players")
        .select("player_id, seat_index, status")
        .eq("lobby_id", lobby.id)
        .eq("status", "active")
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (aliveErr || !alive) return { ok: false, error: `Spieler konnten nicht geladen werden: ${aliveErr?.message ?? ""}` };

    // Helper: unlock/resume mit neuem Timer + optional Holder/Loser
    const resumeRunning = async (args: { holder_player_id: string; last_loser_player_id?: string | null; bumpRound?: boolean }) => {
        const speed = (lobby.round_speed ?? "normal") as RoundSpeed;
        const newExplodeAt = computeExplodeAt(speed, Math.max(2, alive.length)); // safe lower bound
        const newRoundNumber = (lobby.round_number ?? 1) + (args.bumpRound ? 1 : 0);

        const { error } = await supabase
            .from("lobbies")
            .update({
                holder_player_id: args.holder_player_id,
                explode_at: newExplodeAt, // 🔓 UNLOCK
                round_number: newRoundNumber,
                last_loser_player_id: args.last_loser_player_id ?? lobby.holder_player_id ?? null,
                last_activity_at: new Date().toISOString(),
            })
            .eq("id", lobby.id)
            .eq("phase", "running")
            .is("explode_at", null);

        if (error) throw new Error(error.message);
    };

    // Wenn schon fertig (0 oder 1 alive)
    if (alive.length <= 1) {
        const winnerId = alive[0]?.player_id ?? null;

        const { error: finErr } = await supabase
            .from("lobbies")
            .update({
                phase: "finished",
                holder_player_id: winnerId ?? lobby.holder_player_id ?? null,
                last_loser_player_id: loserId,
                last_activity_at: new Date().toISOString(),
            })
            .eq("id", lobby.id)
            .eq("phase", "running")
            .is("explode_at", null);

        if (finErr) return { ok: false, error: `Finish fehlgeschlagen: ${finErr.message}` };
        return { ok: true, didWork: true, finished: true };
    }

    // Holder muss alive sein — falls nicht: korrigieren + unlocken (sonst Soft-Lock)
    const holderIsAlive = alive.some((p) => p.player_id === loserId);
    if (!holderIsAlive) {
        try {
            const fallbackHolder = alive[0].player_id;
            await resumeRunning({ holder_player_id: fallbackHolder, last_loser_player_id: loserId, bumpRound: false });
            return { ok: true, didWork: true, finished: false };
        } catch (e: unknown) {
            return { ok: false, error: `Resume fehlgeschlagen: ${e instanceof Error ? e.message : "Unbekannt"}` };
        }
    }

    // ✅ erst jetzt killen (nach Claim)
    const { error: killErr } = await supabase
        .from("players")
        .update({ is_alive: false })
        .eq("lobby_id", lobby.id)
        .eq("player_id", loserId)
        .eq("is_alive", true);

    if (killErr) {
        // Notfall: unlocken auf ersten alive (damit Game nicht hängt)
        try {
            const fallbackHolder = alive[0]?.player_id ?? loserId;
            await resumeRunning({ holder_player_id: fallbackHolder, last_loser_player_id: loserId, bumpRound: false });
        } catch {
            // ignore secondary
        }
        return { ok: false, error: `Elimination fehlgeschlagen: ${killErr.message}` };
    }

    const { data: aliveAfter, error: afterErr } = await supabase
        .from("players")
        .select("player_id, seat_index, status")
        .eq("lobby_id", lobby.id)
        .eq("status", "active")
        .eq("is_alive", true)
        .order("seat_index", { ascending: true });

    if (afterErr || !aliveAfter) return { ok: false, error: `Spieler konnten nicht geladen werden: ${afterErr?.message ?? ""}` };

    // Wenn jetzt nur noch 1 übrig: Spiel beenden + Winner setzen
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
            .is("explode_at", null) // ✅ unser Lock
            .eq("holder_player_id", loserId) // ✅ sollte unverändert sein (passPotato blockt beim lock)
            .select("id")
            .maybeSingle();

        if (updErr) return { ok: false, error: `Finish fehlgeschlagen: ${updErr.message}` };

        // Falls CAS nicht matcht: trotzdem nicht hängen lassen → fallback finish ohne holder CAS
        if (!finRow) {
            const { error: finErr2 } = await supabase
                .from("lobbies")
                .update({
                    phase: "finished",
                    holder_player_id: aliveAfter[0].player_id,
                    last_loser_player_id: loserId,
                    last_activity_at: new Date().toISOString(),
                })
                .eq("id", lobby.id)
                .eq("phase", "running")
                .is("explode_at", null);

            if (finErr2) return { ok: false, error: `Finish fallback fehlgeschlagen: ${finErr2.message}` };
        }

        return { ok: true, didWork: true, finished: true };
    }

    // Next holder (Seat-Reihenfolge, wrap-around)
    const loserSeat = alive.find((p) => p.player_id === loserId)?.seat_index ?? -1;
    const next = aliveAfter.find((p) => (p.seat_index ?? 0) > loserSeat) ?? aliveAfter[0];
    const nextHolderId = next.player_id;

    const speed = (lobby.round_speed ?? "normal") as RoundSpeed;
    const newExplodeAt = computeExplodeAt(speed, aliveAfter.length);
    const newRoundNumber = (lobby.round_number ?? 1) + 1;

    const { data: updRow, error: updErr } = await supabase
        .from("lobbies")
        .update({
            holder_player_id: nextHolderId,
            explode_at: newExplodeAt, // 🔓 unlock + new timer
            round_number: newRoundNumber,
            last_loser_player_id: loserId,
            last_activity_at: new Date().toISOString(),
        })
        .eq("id", lobby.id)
        .eq("phase", "running")
        .is("explode_at", null) // ✅ nur der Claimer darf weitermachen
        .eq("holder_player_id", loserId) // ✅
        .select("id")
        .maybeSingle();

    if (updErr) return { ok: false, error: `Rundenstart fehlgeschlagen: ${updErr.message}` };

    // Wenn CAS nicht matcht: wir dürfen NICHT "didWork:false" returnen, sonst bleibt explode_at null → Soft-Lock.
    if (!updRow) {
        try {
            await resumeRunning({ holder_player_id: nextHolderId, last_loser_player_id: loserId, bumpRound: true });
            return { ok: true, didWork: true, finished: false };
        } catch (e: unknown) {
            // letzter Notfall: finishen damit nichts hängt
            const { error: finErr } = await supabase
                .from("lobbies")
                .update({ phase: "finished", last_activity_at: new Date().toISOString() })
                .eq("id", lobby.id)
                .eq("phase", "running")
                .is("explode_at", null);

            if (finErr) return { ok: false, error: `Resume+Finish fehlgeschlagen: ${finErr.message}` };
            return { ok: true, didWork: true, finished: true };
        }
    }

    return { ok: true, didWork: true, finished: false };
}