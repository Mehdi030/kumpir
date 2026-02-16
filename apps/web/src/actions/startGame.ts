"use server";

import { createSupabaseAdminClient } from "@/lib/supabaseAdmin";
import { calculateExplodeSeconds, type RoundSpeed } from "@/lib/gameConfig";

export type StartGameResult =
    | { ok: true; alreadyRunning?: boolean }
    | { ok: false; error: string; code?: string };

function err(message: string, code?: string): StartGameResult {
    return { ok: false, error: message, code };
}

export async function startGame(code: string): Promise<StartGameResult> {
    try {
        const supabase = createSupabaseAdminClient();

        const { data: lobby, error: lobbyErr } = await supabase
            .from("lobbies")
            .select("id, code, phase, round_speed")
            .eq("code", code)
            .single();

        if (lobbyErr || !lobby) {
            console.error("startGame: lobby load failed", lobbyErr);
            return err("Lobby nicht gefunden.", "LOBBY_NOT_FOUND");
        }

        if (lobby.phase === "running") return { ok: true, alreadyRunning: true };
        if (lobby.phase === "finished") return err("Spiel ist bereits beendet.", "ALREADY_FINISHED");

        const { data: alive, error: aliveErr } = await supabase
            .from("players")
            .select("player_id, seat_index, ready, is_alive")
            .eq("lobby_id", lobby.id)
            .eq("is_alive", true)
            .order("seat_index", { ascending: true });

        if (aliveErr) {
            console.error("startGame: players load failed", aliveErr);
            return err(`Spieler konnten nicht geladen werden: ${aliveErr.message}`, "PLAYERS_LOAD_FAILED");
        }

        const aliveList = alive ?? [];

        // min. 2 Spieler
        if (aliveList.length < 2) return err("Mindestens 2 Spieler nötig.", "NEED_PLAYERS");

        if (!aliveList.every((p) => !!p.ready)) return err("Nicht alle Spieler sind bereit.", "NOT_ALL_READY");

        const startHolder = aliveList[Math.floor(Math.random() * aliveList.length)].player_id;

        const speed = (lobby.round_speed ?? "normal") as RoundSpeed;
        const explodeInSec = calculateExplodeSeconds(speed, aliveList.length, {
            exponent: 1.9,
            quantizeStepSec: 0.5,
            clampMinSec: 3,
        });

        const now = Date.now();
        const nowIso = new Date(now).toISOString();
        const explodeAt = new Date(now + explodeInSec * 1000).toISOString();

        // ✅ idempotent update (setzt run_started_at nur beim echten Start)
        const { data: updatedLobby, error: updErr } = await supabase
            .from("lobbies")
            .update({
                phase: "running",
                holder_player_id: startHolder,
                explode_at: explodeAt,
                round_number: 1,
                last_loser_player_id: null,
                last_activity_at: nowIso,

                // ✅ NEU: server-anker für synchronen Countdown
                run_started_at: nowIso,
            })
            .eq("id", lobby.id)
            .neq("phase", "running")
            .select("id, phase")
            .maybeSingle();

        if (updErr) {
            console.error("startGame: lobbies update failed", updErr);
            return err(`Start fehlgeschlagen: ${updErr.message}`, "LOBBY_UPDATE_FAILED");
        }

        // jemand anders hat in der Zwischenzeit gestartet
        if (!updatedLobby) return { ok: true, alreadyRunning: true };

        // best effort: reset ready flags
        const { error: resetErr } = await supabase
            .from("players")
            .update({ ready: false })
            .eq("lobby_id", lobby.id);

        if (resetErr) {
            console.warn("startGame: ready reset failed", resetErr);
        }

        return { ok: true };
    } catch (e: unknown) {
        console.error("startGame: unexpected error", e);
        const msg = e instanceof Error ? e.message : "Unbekannter Serverfehler";
        return err(msg, "UNEXPECTED");
    }
}