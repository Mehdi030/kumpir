"use client";

import Link from "next/link";
import Image from "next/image";
import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

function normalizeCode(input: string) {
    return input.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 4);
}

function sanitizeName(input: string) {
    return input.replace(/[^A-Za-zÄÖÜäöüß]/g, "").slice(0, 12);
}

function setStoredName(name: string) {
    if (typeof window === "undefined") return;
    localStorage.setItem("kumpir_player_name", name);
    try {
        sessionStorage.setItem("kumpir_player_name", name);
    } catch {}
}

function setStoredPlayerId(id: string) {
    if (typeof window === "undefined") return;
    localStorage.setItem("kumpir_player_id", id);
    try {
        sessionStorage.setItem("kumpir_player_id", id);
    } catch {}
}

function getStoredName() {
    if (typeof window === "undefined") return "";
    return localStorage.getItem("kumpir_player_name") || "";
}

function getErrorMessage(err: unknown): string {
    if (err instanceof Error) return err.message;
    if (typeof err === "object" && err !== null && "message" in err) {
        const m = (err as { message?: unknown }).message;
        if (typeof m === "string") return m;
    }
    return "Unbekannter Fehler.";
}

export default function JoinClient({ initialCode }: { initialCode: string }) {
    const supabase = getSupabaseClient();
    const router = useRouter();

    const fixedCodeFromLink = normalizeCode(initialCode);
    const hasFixedCode = fixedCodeFromLink.length === 4;

    const [mounted, setMounted] = useState(false);
    const [code, setCode] = useState(() => fixedCodeFromLink);
    const [name, setName] = useState("");

    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);

    const [showNameModal] = useState<boolean>(hasFixedCode);

    const nameInputRef = useRef<HTMLInputElement | null>(null);
    const inFlightRef = useRef(false);

    useEffect(() => {
        setMounted(true);
        setName(getStoredName());
    }, []);

    useEffect(() => {
        if (!showNameModal) return;
        const t = window.setTimeout(() => nameInputRef.current?.focus(), 50);
        return () => window.clearTimeout(t); // ✅ FIX: clearTimeout
    }, [showNameModal]);

    const canJoin = useMemo(() => {
        if (!mounted) return false;
        const c = normalizeCode(code);
        return c.length === 4 && name.trim().length >= 2;
    }, [mounted, code, name]);

    async function joinLobby() {
        if (inFlightRef.current) return;

        setError(null);
        setLoading(true);
        inFlightRef.current = true;

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

            // ✅ Lobby-Status check (locked)
            const { data: lobbyRow, error: lobbyErr } = await supabase
                .from("lobbies")
                .select("locked")
                .eq("code", lobbyCode)
                .maybeSingle();

            if (lobbyErr) {
                setError(lobbyErr.message || "Lobby konnte nicht geprüft werden.");
                return;
            }
            if (!lobbyRow) {
                setError("Lobby nicht gefunden.");
                return;
            }
            if (lobbyRow.locked) {
                setError("Diese Lobby ist gerade gesperrt (🔒).");
                return;
            }

            const { data, error: rpcErr } = await supabase.rpc("join_lobby", {
                p_lobby_code: lobbyCode,
                p_name: playerName,
            });

            if (rpcErr) {
                setError(rpcErr.message || "Konnte der Lobby nicht beitreten.");
                return;
            }

            const pid = typeof data === "string" ? data : String(data);
            setStoredPlayerId(pid);

            router.push(`/lobby/${lobbyCode}`);
        } catch (err: unknown) {
            setError(getErrorMessage(err));
        } finally {
            setLoading(false);
            inFlightRef.current = false;
        }
    }

    function onModalKeyDown(e: React.KeyboardEvent) {
        if (e.key === "Enter") {
            e.preventDefault();
            if (!loading && canJoin) void joinLobby(); // ✅ void
        }
        if (e.key === "Escape") {
            e.preventDefault();
        }
    }

    if (!mounted) return null;

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
                <section
                    className="card"
                    aria-label="Lobby beitreten"
                    style={{ maxWidth: 760, margin: "0 auto" }}
                >
                    <header className="hostHeader" style={{ paddingBottom: 10 }}>
                        <h1 className="h1" style={{ lineHeight: 1.05 }}>
                            Lobby beitreten
                        </h1>
                        <p className="p subline" style={{ marginTop: 8 }}>
                            Schnell rein – ohne Account.
                        </p>
                    </header>

                    {!hasFixedCode ? (
                        <div className="panel" style={{ width: "100%", maxWidth: 540, margin: "0 auto" }}>
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
                                            placeholder="z.B. 5KJ1"
                                            maxLength={4}
                                            spellCheck={false}
                                            autoCorrect="off"
                                            autoCapitalize="characters"
                                            inputMode="text"
                                        />
                                    </div>
                                    <div className="fieldHelp">4 Zeichen (A–Z, 0–9).</div>
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

                            <div style={{ display: "grid", gap: 10, marginTop: 14 }}>
                                <button
                                    type="button"
                                    className={`btn btnPrimary btnSmall ${canJoin && !loading ? "btnGlow" : "btnDisabled"}`}
                                    onClick={() => void joinLobby()} // ✅ void
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
                        </div>
                    ) : (
                        <div className="panel" style={{ width: "100%", maxWidth: 540, margin: "0 auto" }}>
                            <div className="fieldHelp" style={{ opacity: 0.9 }}>
                                Code erkannt: <b style={{ letterSpacing: 1 }}>{fixedCodeFromLink}</b>
                            </div>
                            <div className="fieldHelp" style={{ marginTop: 6, opacity: 0.8 }}>
                                Gib kurz deinen Namen ein, dann geht’s direkt in die Lobby.
                            </div>
                        </div>
                    )}

                    {hasFixedCode && showNameModal ? (
                        <div
                            onKeyDown={onModalKeyDown}
                            style={{
                                position: "fixed",
                                inset: 0,
                                zIndex: 2000,
                                display: "grid",
                                placeItems: "center",
                                background: "rgba(0,0,0,0.45)",
                                backdropFilter: "blur(6px)",
                                WebkitBackdropFilter: "blur(6px)",
                                padding: 16,
                            }}
                        >
                            <div
                                style={{
                                    width: "min(520px, 100%)",
                                    borderRadius: 22,
                                    padding: 18,
                                    border: "1px solid rgba(255,255,255,0.18)",
                                    background: "rgba(0,0,0,0.32)",
                                    boxShadow: "0 22px 70px rgba(0,0,0,0.45)",
                                }}
                            >
                                <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "center" }}>
                                    <div style={{ fontWeight: 950, fontSize: 18 }}>Name eingeben</div>
                                    <div className="pillChip" style={{ height: 30, display: "flex", alignItems: "center" }}>
                                        {fixedCodeFromLink}
                                    </div>
                                </div>

                                <div className="fieldHelp" style={{ marginTop: 6, opacity: 0.85 }}>
                                    Nur kurz – dann bist du drin.
                                </div>

                                <div style={{ marginTop: 12 }}>
                                    <label className="fieldLabel" htmlFor="modalName">
                                        Dein Name
                                    </label>
                                    <div className="fieldControl" style={{ marginTop: 8 }}>
                                        <input
                                            id="modalName"
                                            ref={nameInputRef}
                                            className="input"
                                            value={name}
                                            onChange={(e) => setName(sanitizeName(e.target.value))}
                                            placeholder="z.B. Medo"
                                            maxLength={12}
                                            autoComplete="nickname"
                                            inputMode="text"
                                            spellCheck={false}
                                            autoCorrect="off"
                                        />
                                    </div>
                                    <div className="fieldHelp" style={{ marginTop: 6 }}>
                                        Enter = Join
                                    </div>
                                </div>

                                {error ? (
                                    <div className="fieldHelp fieldHelpError" style={{ marginTop: 12 }}>
                                        {error}
                                    </div>
                                ) : null}

                                <div style={{ display: "flex", gap: 10, marginTop: 14, justifyContent: "flex-end" }}>
                                    <button
                                        type="button"
                                        className={`btn btnPrimary btnSmall ${canJoin && !loading ? "btnGlow" : "btnDisabled"}`}
                                        onClick={() => void joinLobby()} // ✅ void
                                        disabled={!canJoin || loading}
                                    >
                                        {loading ? "Trete bei…" : "🚀 Beitreten"}
                                    </button>
                                </div>
                            </div>
                        </div>
                    ) : null}
                </section>
            </div>
        </main>
    );
}