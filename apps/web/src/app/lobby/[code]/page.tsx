"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabaseClient";
import { useParams } from "next/navigation";

type Player = {
    id: string;
    name: string;
    joined_at: string;
};

export default function LobbyPage() {
    const params = useParams<{ code: string }>();
    const code = String(params.code);

    const [players, setPlayers] = useState<Player[]>([]);
    const [error, setError] = useState<string | null>(null);

    async function loadPlayers() {
        setError(null);

        const { data, error } = await supabase
            .from("players")
            .select("id,name,joined_at")
            .eq("lobby_code", code)
            .order("joined_at", { ascending: true });

        if (error) {
            setError(error.message);
            return;
        }
        setPlayers((data as Player[]) ?? []);
    }

    useEffect(() => {
        if (!code) return;
        loadPlayers();
    }, [code]);

    return (
        <main style={{ padding: 24, maxWidth: 720, margin: "0 auto" }}>
            <h1 style={{ fontSize: 28, fontWeight: 800 }}>Lobby</h1>
            <p style={{ marginTop: 8 }}>
                Lobby‑Code: <strong>{code}</strong>
            </p>

            <div style={{ marginTop: 18 }}>
                <h2 style={{ fontSize: 18, fontWeight: 700 }}>Spieler</h2>
                <button onClick={loadPlayers} style={{ marginTop: 8, padding: 10 }}>
                    Aktualisieren
                </button>

                {error && <p style={{ color: "crimson", marginTop: 10 }}>{error}</p>}

                <ul style={{ marginTop: 12, display: "grid", gap: 8 }}>
                    {players.map((p) => (
                        <li key={p.id} style={{ padding: 10, border: "1px solid #333" }}>
                            {p.name}
                        </li>
                    ))}
                    {players.length === 0 && <li style={{ opacity: 0.7 }}>Noch keine Spieler…</li>}
                </ul>
            </div>
        </main>
    );
}
