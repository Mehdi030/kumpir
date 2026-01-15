"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "../../lib/supabaseClient";

function normalizeCode(input: string) {
    // nur Ziffern, max 4
    return input.replace(/\D/g, "").slice(0, 4);
}

export default function JoinPage() {
    const router = useRouter();
    const [code, setCode] = useState("");
    const [name, setName] = useState("");
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);

    const canJoin = useMemo(() => {
        const c = normalizeCode(code);
        return c.length === 4 && name.trim().length >= 2;
    }, [code, name]);

    async function joinLobby() {
        setError(null);
        setLoading(true);

        try {
            const lobbyCode = normalizeCode(code);
            const playerName = name.trim();

            // 1) Lobby existiert?
            const { data: lobby, error: lobbyErr } = await supabase
                .from("lobbies")
                .select("code,status")
                .eq("code", lobbyCode)
                .maybeSingle();

            if (lobbyErr) throw lobbyErr;
            if (!lobby) {
                setError("Lobby nicht gefunden. Prüfe den Code.");
                return;
            }
            if (lobby.status !== "lobby") {
                setError("Diese Lobby ist schon gestartet oder beendet.");
                return;
            }

            // 2) Spieler eintragen
            const { error: insertErr } = await supabase.from("players").insert([
                {
                    lobby_code: lobbyCode,
                    name: playerName,
                    is_ready: false,
                    is_connected: true,
                },
            ]);

            if (insertErr) {
                const msg = (insertErr as any)?.message?.toLowerCase?.() ?? "";
                const isDuplicate =
                    (insertErr as any)?.code === "23505" ||
                    msg.includes("duplicate") ||
                    msg.includes("unique");

                if (isDuplicate) {
                    setError("Name ist in dieser Lobby schon vergeben. Nimm einen anderen.");
                    return;
                }
                throw insertErr;
            }

            // 3) Weiter zur Lobby
            router.push(`/lobby/${lobbyCode}`);
        } catch (e: any) {
            setError(e?.message ?? "Unbekannter Fehler beim Beitreten.");
        } finally {
            setLoading(false);
        }
    }

    return (
        <main style={{ padding: 24, maxWidth: 720, margin: "0 auto" }}>
            <h1 style={{ fontSize: 28, fontWeight: 800 }}>Join</h1>
            <p style={{ marginTop: 8, opacity: 0.8 }}>
                Tritt einer Lobby mit 4‑stelligem Code bei.
            </p>

            <div style={{ marginTop: 18, display: "grid", gap: 10 }}>
                <label style={{ display: "grid", gap: 6 }}>
                    Lobby‑Code
                    <input
                        value={code}
                        onChange={(e) => setCode(normalizeCode(e.target.value))}
                        placeholder="z.B. 8977"
                        inputMode="numeric"
                        style={{ padding: 10, width: "100%" }}
                    />
                </label>

                <label style={{ display: "grid", gap: 6 }}>
                    Dein Name
                    <input
                        value={name}
                        onChange={(e) => setName(e.target.value)}
                        placeholder="z.B. Sero"
                        style={{ padding: 10, width: "100%" }}
                    />
                </label>

                <button
                    onClick={joinLobby}
                    disabled={!canJoin || loading}
                    style={{
                        padding: 12,
                        cursor: !canJoin || loading ? "not-allowed" : "pointer",
                    }}
                >
                    {loading ? "Trete bei…" : "Beitreten"}
                </button>

                {error && <p style={{ color: "crimson" }}>{error}</p>}
            </div>
        </main>
    );
}
