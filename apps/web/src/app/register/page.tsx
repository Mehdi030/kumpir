"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

function isEmailLike(v: string) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}
function isPhoneLike(v: string) {
    return /^(\+|00)?[0-9][0-9\s-]{6,}$/.test(v.trim());
}
function normalizeUsername(v: string) {
    return v.trim().toLowerCase();
}

export default function RegisterPage() {
    const supabase = getSupabaseClient();

    const [username, setUsername] = useState("");
    const [email, setEmail] = useState("");
    const [phone, setPhone] = useState("");
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
        const p = phone.trim();

        if (u.length < 3) {
            setError("Benutzername muss mindestens 3 Zeichen haben.");
            return;
        }
        if (!/^[a-z0-9._-]+$/.test(u)) {
            setError("Benutzername: nur a-z, 0-9, Punkt, Unterstrich, Minus.");
            return;
        }
        if (password.length < 8) {
            setError("Passwort muss mindestens 8 Zeichen haben.");
            return;
        }

        const hasEmail = e.length > 0;
        const hasPhone = p.length > 0;

        if (!hasEmail && !hasPhone) {
            setError("Bitte E-Mail oder Telefonnummer angeben (für Verifizierung).");
            return;
        }
        if (hasEmail && !isEmailLike(e)) {
            setError("Bitte eine gültige E-Mail eingeben.");
            return;
        }
        if (hasPhone && !isPhoneLike(p)) {
            setError("Bitte eine gültige Telefonnummer eingeben (z.B. +491...).");
            return;
        }

        setLoading(true);
        try {
            if (hasEmail) {
                const { error } = await supabase.auth.signUp({
                    email: e,
                    password,
                    options: {
                        emailRedirectTo: callbackUrl,
                        data: {
                            username: u,
                            phone: hasPhone ? p : null,
                        },
                    },
                });
                if (error) throw error;

                // ✅ redirect to login after signup
                const loginUrl = `/login?next=${encodeURIComponent(nextPath)}&m=account_created`;
                window.location.href = loginUrl;
                return;
            }

            // phone signup
            const { error } = await supabase.auth.signUp({
                phone: p,
                password,
                options: {
                    data: { username: u },
                },
            });
            if (error) throw error;

            // ✅ redirect to login after signup
            const loginUrl = `/login?next=${encodeURIComponent(nextPath)}&m=account_created`;
            window.location.href = loginUrl;
        } catch (e: any) {
            setError(e?.message ?? "Registrierung fehlgeschlagen.");
        } finally {
            setLoading(false);
        }
    }

    const VerifyNote = () => (
        <div
            className="fieldHelp"
            style={{
                opacity: 0.92,
                fontSize: 12,
                lineHeight: 1.35,
            }}
        >
            <b>Verifizierung & Wiederherstellung:</b> Wähle{" "}
            <b>E-Mail</b> <span style={{ opacity: 0.85 }}>oder</span> <b>Telefonnummer</b>.{" "}
            <span style={{ opacity: 0.9 }}>Mindestens eine Angabe ist erforderlich.</span>
        </div>
    );

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Registrieren">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Registrieren</h1>
                        </div>

                        <p className="p hostSub">
                            Erstelle deinen Account und sichere dir deinen Benutzernamen.
                        </p>
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

                                {/* EMAIL */}
                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="email">
                                        E-Mail (empfohlen)
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
                                </div>

                                <div style={{ marginTop: 8 }}>
                                    <VerifyNote />
                                </div>

                                {/* PHONE */}
                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="phone">
                                        Telefonnummer (empfohlen)
                                    </label>

                                    <div className="fieldControl">
                                        <input
                                            id="phone"
                                            className="input"
                                            value={phone}
                                            onChange={(e) => setPhone(e.target.value)}
                                            placeholder="+49123456789"
                                            autoComplete="tel"
                                            inputMode="tel"
                                        />
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

                                    <Link
                                        href={`/login?next=${encodeURIComponent(nextPath)}`}
                                        className="btn btnSecondary"
                                    >
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
                                    🔐 Deine Angaben werden ausschließlich zur Verifizierung und Wiederherstellung genutzt.
                                </div>
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
