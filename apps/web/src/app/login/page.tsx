"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

function isEmailLike(v: string) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}

export default function LoginPage() {
    const supabase = getSupabaseClient();

    const [tab, setTab] = useState<"google" | "email">("google");
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");

    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string>("");
    const [info, setInfo] = useState<string>("");

    const nextPath = useMemo(() => {
        if (typeof window === "undefined") return "/host";
        const url = new URL(window.location.href);
        return url.searchParams.get("next") ?? "/host";
    }, []);

    const callbackUrl = useMemo(() => {
        if (typeof window === "undefined") return "";
        return `${window.location.origin}/auth/callback?next=${encodeURIComponent(nextPath)}`;
    }, [nextPath]);

    // ✅ wenn bereits eingeloggt: sofort weiter
    useEffect(() => {
        (async () => {
            const { data } = await supabase.auth.getSession();
            if (data.session) {
                window.location.href = nextPath;
            }
        })();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    async function signInWithGoogle() {
        setLoading(true);
        setError("");
        setInfo("");

        try {
            const { error } = await supabase.auth.signInWithOAuth({
                provider: "google",
                options: { redirectTo: callbackUrl },
            });
            if (error) throw error;
        } catch (e: any) {
            setError(e?.message ?? "Google Login fehlgeschlagen.");
            setLoading(false);
        }
    }

    async function signInEmail() {
        setLoading(true);
        setError("");
        setInfo("");

        const cleanEmail = email.trim();

        try {
            if (!isEmailLike(cleanEmail)) {
                setError("Bitte eine gültige E-Mail eingeben.");
                setLoading(false);
                return;
            }
            if (password.length < 8) {
                setError("Passwort muss mindestens 8 Zeichen haben.");
                setLoading(false);
                return;
            }

            const { error } = await supabase.auth.signInWithPassword({
                email: cleanEmail,
                password,
            });

            if (error) throw error;

            window.location.href = nextPath;
        } catch (e: any) {
            setError(e?.message ?? "Login fehlgeschlagen.");
            setLoading(false);
        }
    }

    async function signUpEmail() {
        setLoading(true);
        setError("");
        setInfo("");

        const cleanEmail = email.trim();

        try {
            if (!isEmailLike(cleanEmail)) {
                setError("Bitte eine gültige E-Mail eingeben.");
                setLoading(false);
                return;
            }
            if (password.length < 8) {
                setError("Passwort muss mindestens 8 Zeichen haben.");
                setLoading(false);
                return;
            }

            const { error } = await supabase.auth.signUp({
                email: cleanEmail,
                password,
                options: { emailRedirectTo: callbackUrl },
            });

            if (error) throw error;

            setInfo(
                "Account erstellt. Falls E-Mail-Bestätigung aktiv ist: Bitte Mail öffnen und bestätigen, danach wirst du zurückgeleitet."
            );
            setLoading(false);
        } catch (e: any) {
            setError(e?.message ?? "Registrierung fehlgeschlagen.");
            setLoading(false);
        }
    }

    return (
        <main className="container">
            <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
                <Image src="/logo.png" alt="Kumpir Maskottchen" width={400} height={400} priority className="brandLogoImg" />
            </Link>

            <div className="landingWrap">
                <section className="card" aria-label="Login">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Login</h1>

                            <span className="chip" title="Für Lobby-Hosting erforderlich" aria-label="Erforderlich">
                <span
                    className="chipDot"
                    aria-hidden
                    style={{ background: "rgba(34,211,238,.92)", boxShadow: "0 0 0 3px rgba(34,211,238,.18)" }}
                />
                Erforderlich
              </span>
                        </div>

                        <p className="p hostSub">Melde dich an, damit wir deine Lobby eindeutig zuordnen können.</p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel">
                            <div className="panelHead">
                                <div className="panelTitle">Anmelden</div>
                                <div className="panelHint">Dauert ~5 Sekunden</div>
                            </div>

                            <div className="seg" style={{ marginBottom: 12 }}>
                                <button
                                    type="button"
                                    className={`segBtn ${tab === "google" ? "segActive" : ""}`}
                                    onClick={() => setTab("google")}
                                    disabled={loading}
                                >
                                    Google
                                </button>
                                <button
                                    type="button"
                                    className={`segBtn ${tab === "email" ? "segActive" : ""}`}
                                    onClick={() => setTab("email")}
                                    disabled={loading}
                                >
                                    E-Mail
                                </button>
                            </div>

                            {tab === "google" ? (
                                <div className="previewCard" style={{ marginTop: 0 }}>
                                    <div className="previewTop">
                                        <div className="avatar" aria-hidden>
                                            G
                                        </div>
                                        <div className="previewMeta">
                                            <div className="previewName">Google</div>
                                            <div className="previewSub">Schnell • Sicher • Kein Passwort bei uns gespeichert</div>
                                        </div>
                                    </div>

                                    <div className="actionsRow" style={{ marginTop: 14 }}>
                                        <button
                                            type="button"
                                            className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                            onClick={signInWithGoogle}
                                            disabled={loading}
                                        >
                                            {loading ? "Weiterleiten…" : "Mit Google anmelden"}
                                        </button>

                                        <Link href="/" className="btn btnSecondary">
                                            Zurück
                                        </Link>
                                    </div>
                                </div>
                            ) : (
                                <div className="previewCard" style={{ marginTop: 0 }}>
                                    <div className="fieldRow">
                                        <label className="fieldLabel" htmlFor="email">
                                            E-Mail
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

                                    <div className="fieldRow" style={{ marginTop: 10 }}>
                                        <label className="fieldLabel" htmlFor="password">
                                            Passwort
                                        </label>
                                        <div className="fieldControl">
                                            <input
                                                id="password"
                                                className="input"
                                                value={password}
                                                onChange={(e) => setPassword(e.target.value)}
                                                placeholder="mind. 8 Zeichen"
                                                autoComplete="current-password"
                                                type="password"
                                            />
                                        </div>
                                    </div>

                                    <div className="actionsRow" style={{ marginTop: 14 }}>
                                        <button
                                            type="button"
                                            className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                            onClick={signInEmail}
                                            disabled={loading}
                                        >
                                            {loading ? "Login…" : "Einloggen"}
                                        </button>

                                        <button
                                            type="button"
                                            className={`btn btnSecondary ${loading ? "btnDisabled" : ""}`}
                                            onClick={signUpEmail}
                                            disabled={loading}
                                            title="Erstellt einen neuen Account"
                                        >
                                            Registrieren
                                        </button>

                                        <Link href="/" className="btn btnSecondary">
                                            Zurück
                                        </Link>
                                    </div>
                                </div>
                            )}

                            {error ? <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>{error}</div> : null}
                            {info ? <div className="fieldHelp" style={{ marginTop: 10 }}>{info}</div> : null}

                            <div className="fieldHelp" style={{ marginTop: 10, opacity: 0.9 }}>
                                Weiterleitung nach Login: <code>{nextPath}</code>
                            </div>
                        </div>

                        <div className="panel panelAlt">
                            <div className="panelHead">
                                <div className="panelTitle">Warum Login?</div>
                                <div className="panelHint">Kurz erklärt</div>
                            </div>

                            <div className="previewCard">
                                <ul style={{ margin: 0, paddingLeft: 18, lineHeight: 1.35 }}>
                                    <li>Damit <b>host_player_id</b> eine echte UUID ist (auth.users.id).</li>
                                    <li>Damit niemand “fremde” Lobbys übernimmt.</li>
                                    <li>Damit wir später Rollen/Rechte sauber erweitern können.</li>
                                </ul>

                                <div className="fieldHelp" style={{ marginTop: 12 }}>
                                    Tipp: Für Tests kannst du Email-Confirm in Supabase kurz deaktivieren.
                                </div>
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
