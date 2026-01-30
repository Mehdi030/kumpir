"use client";

import Link from "next/link";
import Image from "next/image";
import { useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

function normalizeCode(input: string) {
    return input.toUpperCase().replace(/[^A-Z2-9]/g, "").slice(0, 4);
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
    const params = useSearchParams();

    const [code, setCode] = useState(() => normalizeCode(params.get("code") ?? ""));
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

            // ✅ wenn Session existiert: 3-param-overload nutzen, sonst guest
            const { data: session } = await supabase.auth.getSession();
            const userId = session?.session?.user?.id ?? null;

            const payload: any = { p_lobby_code: lobbyCode, p_name: playerName };
            if (userId) payload.p_user_id = userId;

            const { data, error: rpcErr } = await supabase.rpc("join_lobby", payload);

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
            <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
                <Image
                    src="/logo.png"
                    alt="Kumpir Maskottchen"
                    width={400}
                    height={400}
                    priority
                    className="brandLogoImg"
                />
            </Link>

            <div className="landingWrap">
                <section className="card" aria-label="Lobby beitreten" style={{ maxWidth: 760, margin: "0 auto" }}>
                    <header className="hostHeader" style={{ paddingBottom: 10 }}>
                        <div className="hostTitleRow" style={{ justifyContent: "flex-start", gap: 16, alignItems: "flex-start" }}>
                            <div style={{ maxWidth: 520 }}>
                                <h1 className="h1" style={{ lineHeight: 1.05 }}>
                                    Lobby beitreten
                                </h1>
                                <p className="p subline" style={{ marginTop: 8 }}>
                                    Mitspielen ohne Account. Code rein und los.
                                </p>
                            </div>
                        </div>
                    </header>

                    <div style={{ display: "flex", justifyContent: "center" }}>
                        <div className="panel" style={{ width: "100%", maxWidth: 520, margin: "6px auto 0" }}>
                            <div className="panelHead">
                                <div className="panelTitle">Beitritt</div>
                                <div className="panelHint">Dauert ~5 Sekunden</div>
                            </div>

                            <div style={{ display: "grid", gap: 12 }}>
                                <div className="fieldRow" style={{ margin: 0 }}>
                                    <label className="fieldLabel" htmlFor="code">
                                        Lobby-Code
                                    </label>
                                    <div className="fieldControl">
                                        <input
                                            id="code"
                                            className="input"
                                            value={code}
                                            onChange={(e) => setCode(normalizeCode(e.target.value))}
                                            placeholder="z.B. 5KJQ"
                                            maxLength={4}
                                            spellCheck={false}
                                            autoCorrect="off"
                                            autoCapitalize="characters"
                                            inputMode="text"
                                        />
                                    </div>
                                    <div className="fieldHelp">4 Zeichen (A–Z, 2–9).</div>
                                </div>

                                <div className="fieldRow" style={{ margin: 0 }}>
                                    <label className="fieldLabel" htmlFor="name">
                                        Dein Name
                                    </label>
                                    <div className="fieldControl">
                                        <input
                                            id="name"
                                            className="input"
                                            value={name}
                                            onChange={(e) => setName(e.target.value)}
                                            placeholder="z.B. Sero"
                                            maxLength={24}
                                            autoComplete="nickname"
                                        />
                                    </div>
                                    <div className="fieldHelp">Mindestens 2 Zeichen.</div>
                                </div>
                            </div>

                            {error ? (
                                <div className="fieldHelp fieldHelpError" style={{ marginTop: 12 }}>
                                    {error}
                                </div>
                            ) : null}

                            <div style={{ display: "grid", gap: 10, marginTop: 14 }}>
                                <button
                                    type="button"
                                    className={`btn btnPrimary btnXL ${canJoin && !loading ? "btnGlow" : "btnDisabled"}`}
                                    onClick={joinLobby}
                                    disabled={!canJoin || loading}
                                    style={{ width: "100%" }}
                                >
                                    {loading ? "Trete bei…" : "Beitreten"}
                                </button>

                                <button
                                    type="button"
                                    className="btn btnSecondary btnSmall"
                                    onClick={() => router.push("/")}
                                    disabled={loading}
                                    style={{ width: "100%" }}
                                >
                                    ← Zurück
                                </button>
                            </div>

                            <div className="fieldHelp" style={{ marginTop: 12, opacity: 0.9 }}>
                                Tipp: Gast reicht. Login ist optional.
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
