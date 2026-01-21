"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabaseClient";

function normalizeCode(input: string) {
    // erlaubt A–Z und 2–9 (ohne 0/1), max 4, uppercase
    return input
        .toUpperCase()
        .replace(/[^A-Z2-9]/g, "")
        .slice(0, 4);
}

function getOrCreatePlayerId() {
    const key = "kumpir_player_id";
    const existing =
        typeof window !== "undefined" ? localStorage.getItem(key) : null;
    if (existing) return existing;

    const id = crypto.randomUUID();
    localStorage.setItem(key, id);
    return id;
}

function setStoredName(name: string) {
    localStorage.setItem("kumpir_player_name", name);
}

function getErrorMessage(err: unknown): string {
    if (err instanceof Error) return err.message;
    if (typeof err === "object" && err !== null && "message" in err) {
        const m = (err as { message?: unknown }).message;
        if (typeof m === "string") return m;
    }
    return "Unbekannter Fehler.";
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
            const playerId = getOrCreatePlayerId();

            // local speichern (für LobbyPage Autocomplete)
            setStoredName(playerName);

            // OPTION A: KEIN select/insert auf Tabellen -> nur RPC
            const { error: rpcErr } = await supabase.rpc("rpc_join_lobby", {
                p_code: lobbyCode,
                p_player_id: playerId,
                p_name: playerName,
            });

            if (rpcErr) {
                // Typische rpcErr.message: lobby_not_found, lobby_full, lobby_not_joinable, invalid_name, ...
                setError(rpcErr.message || "Konnte der Lobby nicht beitreten.");
                return;
            }

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
                                        placeholder="z.B. 5KJQ"
                                        inputMode="text"
                                        autoCapitalize="characters"
                                        autoCorrect="off"
                                        spellCheck={false}
                                        autoComplete="one-time-code"
                                        maxLength={4}
                                    />
                                    <span className="helperText">4 Zeichen (A–Z, 2–9).</span>
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
