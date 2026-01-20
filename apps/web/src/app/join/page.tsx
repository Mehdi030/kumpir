"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import type { PostgrestError } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabaseClient";

function normalizeCode(input: string) {
    // nur Ziffern, maximal 4
    return input.replace(/\D/g, "").slice(0, 4);
}

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

            if (lobbyErr) {
                setError(lobbyErr.message);
                return;
            }

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
                if (isDuplicateError(insertErr)) {
                    setError("Name ist in dieser Lobby schon vergeben. Nimm einen anderen.");
                    return;
                }
                setError(insertErr.message);
                return;
            }

            // 3) Weiter zur Lobby
            router.push(`/lobby/${lobbyCode}`);
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
                    <h1 className="h1">Lobby beitreten</h1>
                    <p className="p subline">Mitspielen ohne Account. Code rein und los.</p>

                    <div className="stepsWrap">
                        <div className="stepsBox">
                            <div className="stepsTitle">Beitritt</div>

                            <div className="formGrid">
                                <label className="fieldLabel">
                                    Lobby-Code
                                    <input
                                        className="textInput"
                                        value={code}
                                        onChange={(e) => setCode(normalizeCode(e.target.value))}
                                        placeholder="z.B. 8977"
                                        inputMode="numeric"
                                        autoComplete="one-time-code"
                                    />
                                    <span className="helperText">4 Ziffern.</span>
                                </label>

                                <label className="fieldLabel">
                                    Dein Name
                                    <input
                                        className="textInput"
                                        value={name}
                                        onChange={(e) => setName(e.target.value)}
                                        placeholder="z.B. Sero"
                                        autoComplete="nickname"
                                        maxLength={24}
                                    />
                                    <span className="helperText">Mindestens 2 Zeichen.</span>
                                </label>

                                <div className="ctaRow">
                                    <button
                                        type="button"
                                        className="btn btnPrimary"
                                        onClick={joinLobby}
                                        disabled={!canJoin || loading}
                                        aria-disabled={!canJoin || loading}
                                    >
                                        {loading ? "Trete bei…" : "Beitreten"}
                                    </button>

                                    <button
                                        type="button"
                                        className="btn btnSecondary"
                                        onClick={() => router.push("/")}
                                        disabled={loading}
                                        aria-disabled={loading}
                                    >
                                        Zurück
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
