"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

function isEmailLike(v: string) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}
function normalizeUsername(v: string) {
    return v.trim().toLowerCase();
}

export default function RegisterPage() {
    const supabase = getSupabaseClient();

    const [username, setUsername] = useState("");
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");

    const [loading, setLoading] = useState(false);
    const [error, setError] = useState("");
    const [info, setInfo] = useState("");

    const nextPath = useMemo(() => {
        if (typeof window === "undefined") return "/host";
        const url = new URL(window.location.href);
        const next = url.searchParams.get("next");
        return next && next.startsWith("/") ? next : "/host";
    }, []);

    // Nach Email-Confirm landet der User hier und wird (wenn callback korrekt ist) automatisch eingeloggt
    const callbackUrl = useMemo(() => {
        if (typeof window === "undefined") return "";
        return `${window.location.origin}/auth/callback?next=${encodeURIComponent(nextPath)}`;
    }, [nextPath]);

    async function onSubmit() {
        if (loading) return;

        setError("");
        setInfo("");

        const u = normalizeUsername(username);
        const e = email.trim();

        if (u.length < 3) {
            setError("Benutzername muss mindestens 3 Zeichen haben.");
            return;
        }
        if (!/^[a-z0-9._-]+$/.test(u)) {
            setError("Benutzername: nur a-z, 0-9, Punkt, Unterstrich, Minus.");
            return;
        }

        if (!isEmailLike(e)) {
            setError("Bitte eine gültige E-Mail eingeben.");
            return;
        }

        if (password.length < 8) {
            setError("Passwort muss mindestens 8 Zeichen haben.");
            return;
        }

        setLoading(true);
        try {
            const { error } = await supabase.auth.signUp({
                email: e,
                password,
                options: {
                    emailRedirectTo: callbackUrl,
                    data: {
                        username: u,
                    },
                },
            });
            if (error) throw error;

            // Direkt in den "Email bestätigen" Screen
            const loginUrl =
                `/login?next=${encodeURIComponent(nextPath)}` +
                `&m=check_email` +
                `&email=${encodeURIComponent(e)}`;

            window.location.href = loginUrl;
        } catch (e: any) {
            setError(e?.message ?? "Registrierung fehlgeschlagen.");
        } finally {
            setLoading(false);
        }
    }

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Registrieren">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Registrieren</h1>
                        </div>

                        <p className="p hostSub">Erstelle deinen Account und sichere dir deinen Benutzernamen.</p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel" style={{ gridColumn: "1 / -1" }}>
                            <div className="previewCard">
                                {/* USERNAME */}
                                <div className="fieldRow">
                                    <label className="fieldLabel" htmlFor="username">
                                        Benutzername *
                                    </label>

                                    <div
                                        style={{
                                            display: "flex",
                                            alignItems: "center",
                                            gap: 14,
                                            width: "100%",
                                        }}
                                    >
                                        <div className="fieldControl" style={{ flex: "0 1 62%" }}>
                                            <input
                                                id="username"
                                                className="input"
                                                value={username}
                                                onChange={(e) => setUsername(e.target.value)}
                                                placeholder="z.B. Medo"
                                                autoComplete="username"
                                            />
                                            <div className="fieldHelp"></div>
                                        </div>

                                        <div
                                            className="fieldHelp"
                                            style={{
                                                flex: "1 1 auto",
                                                textAlign: "left",
                                                whiteSpace: "nowrap",
                                                opacity: 0.9,
                                            }}
                                        >
                                            <b>Mindestens 3 Zeichen</b>
                                        </div>
                                    </div>
                                </div>

                                {/* EMAIL (Pflicht) */}
                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="email">
                                        E-Mail *
                                    </label>

                                    <div className="fieldControl">
                                        <input
                                            id="email"
                                            className="input"
                                            value={email}
                                            onChange={(e) => setEmail(e.target.value)}
                                            placeholder="du@beispiel.de"
                                            autoComplete="email"
                                            inputMode="email"
                                        />
                                    </div>

                                    <div className="fieldHelp" style={{ marginTop: 8, opacity: 0.92, fontSize: 12, lineHeight: 1.35 }}>
                                        <b>Verifizierung:</b> Du bekommst eine Bestätigungs-Mail. Erst danach ist dein Konto aktiv.
                                    </div>
                                </div>

                                {/* PASSWORD */}
                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="password">
                                        Passwort *
                                    </label>

                                    <div className="fieldControl">
                                        <input
                                            id="password"
                                            className="input"
                                            type="password"
                                            value={password}
                                            onChange={(e) => setPassword(e.target.value)}
                                            placeholder="mind. 8 Zeichen"
                                            autoComplete="new-password"
                                        />
                                    </div>
                                </div>

                                {error ? (
                                    <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>
                                        {error}
                                    </div>
                                ) : null}

                                {info ? (
                                    <div className="fieldHelp" style={{ marginTop: 10 }}>
                                        {info}
                                    </div>
                                ) : null}

                                <div className="actionsRow" style={{ marginTop: 14 }}>
                                    <button
                                        type="button"
                                        className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                        onClick={onSubmit}
                                        disabled={loading}
                                    >
                                        {loading ? "…" : "Account erstellen"}
                                    </button>

                                    <Link href={`/login?next=${encodeURIComponent(nextPath)}`} className="btn btnSecondary">
                                        Zurück zum Login
                                    </Link>
                                </div>

                                <div
                                    className="fieldHelp"
                                    style={{
                                        marginTop: 12,
                                        textAlign: "right",
                                        opacity: 0.9,
                                        fontSize: 13,
                                        fontWeight: 600,
                                    }}
                                >
                                    🔐 Wir nutzen deine E-Mail nur für Verifizierung und Wiederherstellung.
                                </div>
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
