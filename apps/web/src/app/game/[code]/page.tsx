"use client";

import { useEffect, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

import { GameBoard } from "@/components/game/GameBoard";
import { passPotato } from "@/actions/passPotato";
import { tickGame } from "@/actions/tickGame";
import { usePlayerIdentity } from "@/hooks/usePlayerIdentity";

type LobbyState = {
    holder_player_id: string | null;
    phase: "running" | "round_end" | "finished" | string;
};

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

export default function GamePage() {
    const supabase = getSupabaseClient();
    const router = useRouter();
    const params = useParams<{ code: string }>();
    const code = String(params.code ?? "").toUpperCase();

    const { mePlayerId } = usePlayerIdentity();

    const [lobby, setLobby] = useState<LobbyState | null>(null);
    const [players, setPlayers] = useState<Player[]>([]);
    const inFlightTickRef = useRef(false);

    useEffect(() => {
        let alive = true;

        async function load() {
            // ✅ prevent overlaps if interval fires while awaiting
            if (inFlightTickRef.current) return;
            inFlightTickRef.current = true;

            try {
                // 🔥 Server tick: explosion/elimination/next round
                try {
                    await tickGame(code);
                } catch {
                    // ignore: eventual consistency is fine
                }

                const lobbyRes = await supabase
                    .from("lobbies")
                    .select("id, holder_player_id, phase")
                    .eq("code", code)
                    .single();

                if (!alive || lobbyRes.error || !lobbyRes.data) return;

                if (lobbyRes.data.phase === "finished") {
                    router.replace("/");
                    return;
                }

                setLobby({
                    holder_player_id: lobbyRes.data.holder_player_id,
                    phase: lobbyRes.data.phase,
                });

                const playersRes = await supabase
                    .from("players")
                    .select("player_id,name,is_alive")
                    .eq("lobby_id", lobbyRes.data.id)
                    .order("seat_index", { ascending: true });

                if (!alive || playersRes.error) return;

                setPlayers(playersRes.data as Player[]);
            } finally {
                inFlightTickRef.current = false;
            }
        }

        load();
        const t = window.setInterval(load, 700);

        return () => {
            alive = false;
            window.clearInterval(t);
        };
    }, [code, supabase, router]);

    async function handlePass() {
        if (!mePlayerId) return;
        try {
            await passPotato(code, mePlayerId);
        } catch {
            // ok: next poll will show truth
        }
    }

    if (!lobby) {
        return <div className="p-6 opacity-70">Lade Spiel…</div>;
    }

    return (
        <GameBoard
            lobbyCode={code}
            holderPlayerId={lobby.holder_player_id}
            players={players}
            mePlayerId={mePlayerId}
            heatLevel="low" // later: derive from explode_at or server flag
            onPass={handlePass}
        />
    );
}