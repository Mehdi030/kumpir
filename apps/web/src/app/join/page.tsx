"use client";

import Link from "next/link";
import Image from "next/image";
import { useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

function normalizeCode(input: string) {
    // ✅ nur A–Z und 2–9, max 4
    return input.toUpperCase().replace(/[^A-Z2-9]/g, "").slice(0, 4);
}

function sanitizeName(input: string) {
    // ✅ nur Buchstaben (inkl. Umlaute), Leerzeichen raus, max 12
    return input.replace(/[^A-Za-zÄÖÜäöüß]/g, "").slice(0, 12);
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
            const playerName = sanitizeName(name).trim();

            if (lobbyCode.length !== 4) {
                setError("Bitte einen gültigen 4-stelligen Code eingeben.");
                return;
            }
            if (playerName.length < 2) {
                setError("Name muss mindestens 2 Buchstaben haben.");
                return;
            }

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
                <Image src="/logo.png" alt="Kumpir Maskottchen" width={400} height={400} priority className="brandLogoImg" />
            </Link>

            <div className="landingWrap">
                <section className="card" aria-label="Lobby beitreten" style={{ maxWidth: 760, margin: "0 auto" }}>
                    <header className="hostHeader" style={{ paddingBottom: 10 }}>
                        <h1 className="h1" style={{ lineHeight: 1.05 }}>
                            Lobby beitreten
                        </h1>
                        <p className="p subline" style={{ marginTop: 8 }}>
                            Schnell rein – ohne Account.
                        </p>
                    </header>

                    <div className="panel" style={{ width: "100%", maxWidth: 540, margin: "0 auto" }}>
                        <div style={{ display: "flex", gap: 8, alignItems: "center", marginBottom: 12, opacity: 0.95 }}>
              <span className="chip">
                <span className="chipDot" aria-hidden />1 Code
              </span>
                            <span style={{ opacity: 0.5 }}>→</span>
                            <span className="chip">
                <span className="chipDot" aria-hidden />2 Name
              </span>
                            <span style={{ opacity: 0.5 }}>→</span>
                            <span className="chip">
                <span className="chipDot" aria-hidden />3 Start
              </span>
                        </div>

                        <div className="divider" />

                        <div style={{ display: "grid", gap: 12, marginTop: 12 }}>
                            <div className="fieldRow" style={{ margin: 0 }}>
                                <label className="fieldLabel" htmlFor="code">
                                    1) Lobby-Code
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
                                    2) Dein Name
                                </label>
                                <div className="fieldControl">
                                    <input
                                        id="name"
                                        className="input"
                                        value={name}
                                        onChange={(e) => setName(sanitizeName(e.target.value))}
                                        placeholder="z.B. Sero"
                                        maxLength={12}
                                        autoComplete="nickname"
                                        inputMode="text"
                                        spellCheck={false}
                                        autoCorrect="off"
                                    />
                                </div>
                                <div className="fieldHelp">Nur Buchstaben, max. 12 Zeichen.</div>
                            </div>
                        </div>

                        {error ? (
                            <div className="fieldHelp fieldHelpError" style={{ marginTop: 12 }}>
                                {error}
                            </div>
                        ) : null}

                        {/* ✅ Buttons kleiner */}
                        <div style={{ display: "grid", gap: 10, marginTop: 14 }}>
                            <button
                                type="button"
                                className={`btn btnPrimary btnSmall ${canJoin && !loading ? "btnGlow" : "btnDisabled"}`}
                                onClick={joinLobby}
                                disabled={!canJoin || loading}
                                style={{ width: "100%", maxWidth: 360, margin: "0 auto" }}
                            >
                                {loading ? "Trete bei…" : "Start"}
                            </button>

                            <button
                                type="button"
                                className="btn btnSecondary btnSmall"
                                onClick={() => router.push("/")}
                                disabled={loading}
                                style={{ width: "100%", maxWidth: 360, margin: "0 auto" }}
                            >
                                ← Zurück
                            </button>
                        </div>

                        <div className="fieldHelp" style={{ marginTop: 12, opacity: 0.9 }}>
                            Tipp: Gast reicht. Login ist optional.
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
