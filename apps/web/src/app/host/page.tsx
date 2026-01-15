"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "../../lib/supabaseClient";
import { generate4DigitCode } from "../../lib/code";

export default function HostPage() {
    const router = useRouter();
    const [hostName, setHostName] = useState("");
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);

    const canCreate = useMemo(() => hostName.trim().length >= 2, [hostName]);

    async function createLobby() {
        setError(null);
        setLoading(true);

        try {
            // 4-stelliger Code kann kollidieren -> ein paar Retries
            for (let attempt = 0; attempt < 12; attempt++) {
                const code = generate4DigitCode();

                const { error: insertError } = await supabase
                    .from("lobbies")
                    .insert([{ code, host_name: hostName.trim(), status: "lobby" }]);

                if (!insertError) {
                    // optional: game_state direkt anlegen (für später)
                    await supabase.from("game_state").insert([{ lobby_code: code }]).throwOnError();

                    router.push(`/lobby/${code}`);
                    return;
                }

                // Duplicate PK -> neuen Code probieren, sonst echter Fehler
                const pgCode = (insertError as any)?.code;
                const msg = ((insertError as any)?.message ?? "").toLowerCase();
                const isDuplicate = pgCode === "23505" || msg.includes("duplicate") || msg.includes("unique");

                if (!isDuplicate) throw insertError;
            }

            setError("Konnte keinen freien Code finden. Bitte nochmal versuchen.");
        } catch (e: any) {
            setError(e?.message ?? "Unbekannter Fehler beim Erstellen der Lobby.");
        } finally {
            setLoading(false);
        }
    }

    return (
        <main style={{ padding: 24, maxWidth: 720, margin: "0 auto" }}>
            <h1 style={{ fontSize: 28, fontWeight: 800 }}>Host</h1>
            <p style={{ marginTop: 8, opacity: 0.8 }}>
                Erstelle eine Lobby. Starten passiert später manuell im Lobby‑Screen.
            </p>

            <div style={{ marginTop: 18, display: "grid", gap: 10 }}>
                <label style={{ display: "grid", gap: 6 }}>
                    Host‑Name
                    <input
                        value={hostName}
                        onChange={(e) => setHostName(e.target.value)}
                        placeholder="z.B. Medo"
                        style={{ padding: 10, width: "100%" }}
                    />
                </label>

                <button
                    onClick={createLobby}
                    disabled={!canCreate || loading}
                    style={{
                        padding: 12,
                        cursor: !canCreate || loading ? "not-allowed" : "pointer",
                    }}
                >
                    {loading ? "Erstelle…" : "Lobby erstellen"}
                </button>

                {error && <p style={{ color: "crimson" }}>{error}</p>}
            </div>
        </main>
    );
}
