"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import type { PostgrestError } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabaseClient";
import { generate4DigitCode } from "@/lib/code";

function getErrorMessage(err: unknown): string {
    if (err instanceof Error) return err.message;
    if (typeof err === "object" && err !== null && "message" in err) {
        const m = (err as { message?: unknown }).message;
        if (typeof m === "string") return m;
    }
    return "Unbekannter Fehler.";
}

function isDuplicateError(err: PostgrestError): boolean {
    const code = err.code ?? "";
    const msg = (err.message ?? "").toLowerCase();
    return code === "23505" || msg.includes("duplicate") || msg.includes("unique");
}

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
                    const { error: gsErr } = await supabase
                        .from("game_state")
                        .insert([{ lobby_code: code }]);

                    if (gsErr) {
                        setError(`Lobby erstellt, aber game_state fehlgeschlagen: ${gsErr.message}`);
                        return;
                    }

                    router.push(`/lobby/${code}`);
                    return;
                }

                // Duplicate PK -> neuen Code probieren, sonst echter Fehler
                if (!isDuplicateError(insertError)) {
                    setError(insertError.message);
                    return;
                }
            }

            setError("Konnte keinen freien Code finden. Bitte nochmal versuchen.");
        } catch (err: unknown) {
            setError(getErrorMessage(err));
        } finally {
            setLoading(false);
        }
    }

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card">
                    <h1 className="h1">Lobby hosten</h1>
                    <p className="p subline">Erstelle eine Lobby und starte später im Lobby-Screen.</p>

                    <div className="stepsWrap">
                        <div className="stepsBox">
                            <div className="stepsTitle">Host-Details</div>

                            <div className="formGrid">
                                <label className="fieldLabel">
                                    Host-Name
                                    <input
                                        className="textInput"
                                        value={hostName}
                                        onChange={(e) => setHostName(e.target.value)}
                                        placeholder="z.B. Medo"
                                        autoComplete="nickname"
                                        maxLength={24}
                                    />
                                    <span className="helperText">Mindestens 2 Zeichen.</span>
                                </label>

                                <div className="ctaRow">
                                    <button
                                        type="button"
                                        className="btn btnPrimary"
                                        onClick={createLobby}
                                        disabled={!canCreate || loading}
                                        aria-disabled={!canCreate || loading}
                                    >
                                        {loading ? "Erstelle…" : "Lobby erstellen"}
                                    </button>

                                    <button
                                        type="button"
                                        className="btn btnSecondary"
                                        onClick={() => router.push("/join")}
                                        disabled={loading}
                                        aria-disabled={loading}
                                    >
                                        Lieber beitreten
                                    </button>
                                </div>

                                {error && <p className="errorText">{error}</p>}
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
