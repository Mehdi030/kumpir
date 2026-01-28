"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { AuthMini } from "@/components/AuthMini";

function normalizeCode(input: string) {
    return input
        .toUpperCase()
        .replace(/[^A-Z2-9]/g, "")
        .slice(0, 4);
}

function setStoredName(name: string) {
    localStorage.setItem("kumpir_player_name", name);
}

function setStoredPlayerId(id: string) {
    localStorage.setItem("kumpir_player_id", id);
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
    const supabase = getSupabaseClient();
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

            setStoredName(playerName);

            // join_lobby(p_lobby_code, p_name) -> uuid
            const { data, error: rpcErr } = await supabase.rpc("join_lobby", {
                p_lobby_code: lobbyCode,
                p_name: playerName,
            });

            if (rpcErr) {
                setError(rpcErr.message || "Konnte der Lobby nicht beitreten.");
                return;
            }

            setStoredPlayerId(String(data));
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
                    <div className="hostTitleRow" style={{ justifyContent: "space-between", gap: 12 }}>
                        <div>
                            <h1 className="h1">Lobby beitreten</h1>
                            <p className="p subline">Mitspielen ohne Account. Code rein und los.</p>
                        </div>

                        {/* ✅ optional sichtbar */}
                        <AuthMini nextPath="/join" variant="header" />
                    </div>

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
