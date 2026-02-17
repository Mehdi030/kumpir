"use client";

import { useEffect, useRef } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

type Opts = {
    lobbyId: string | null | undefined;
    playerId: string | null | undefined;

    intervalMs?: number; // heartbeat default 8000
    doCleanup?: boolean; // default true
    cleanupEveryMs?: number; // default 15000
    staleSeconds?: number; // default 25
};

export function useHeartbeat(opts: Opts) {
    const supabase = getSupabaseClient();
    const inFlightRef = useRef(false);
    const lastCleanupAtRef = useRef(0);

    const lobbyId = opts.lobbyId ?? null;
    const playerId = opts.playerId ?? null;

    const intervalMs = opts.intervalMs ?? 8000;
    const doCleanup = opts.doCleanup ?? true;
    const cleanupEveryMs = opts.cleanupEveryMs ?? 15000;
    const staleSeconds = opts.staleSeconds ?? 25;

    useEffect(() => {
        if (!lobbyId || !playerId) return;

        let alive = true;

        const tick = async () => {
            if (!alive) return;
            if (inFlightRef.current) return;
            inFlightRef.current = true;

            try {
                await supabase.rpc("rpc_heartbeat", {
                    p_lobby_id: lobbyId,
                    p_player_id: playerId,
                });

                if (doCleanup) {
                    const now = Date.now();
                    if (now - lastCleanupAtRef.current >= cleanupEveryMs) {
                        lastCleanupAtRef.current = now;
                        await supabase.rpc("cleanup_lobby", {
                            p_lobby_id: lobbyId,
                            p_stale_seconds: staleSeconds,
                        });
                    }
                }
            } catch {
                // silent by design
            } finally {
                inFlightRef.current = false;
            }
        };

        void tick();
        const t = window.setInterval(() => void tick(), intervalMs);

        return () => {
            alive = false;
            window.clearInterval(t);
        };
    }, [supabase, lobbyId, playerId, intervalMs, doCleanup, cleanupEveryMs, staleSeconds]);
}