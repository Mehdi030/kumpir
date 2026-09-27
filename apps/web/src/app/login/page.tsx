"use client";

import Link from "next/link";
import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { loginWithIdentifier } from "@/actions/login";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";

function safeNextPath(v: string | null) {
    if (!v) return "/host";
    if (!v.startsWith("/")) return "/host";
    if (v.startsWith("//")) return "/host";
    return v;
}

function LoginInner() {
    const router = useRouter();
    const sp = useSearchParams();
    const { user, loading: authLoading } = useAuth();

    const nextPath = safeNextPath(sp.get("next"));
    const msg = sp.get("m");
    const preloadEmail = sp.get("email") ?? "";
    const errorParam = sp.get("error");
    const errorDescParam = sp.get("error_description");

    const [identifier, setIdentifier] = useState(preloadEmail); // email oder username
    const [password, setPassword] = useState("");
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState("");
    const [info, setInfo] = useState("");

    const initialNotice = useMemo(() => {
        if (msg === "check_email" && preloadEmail) {
            return `📨 Bestätigungsmail an ${preloadEmail} gesendet. Klick den Link, dann hier einloggen.`;
        }
        if (msg === "auth_error" && (errorParam || errorDescParam)) {
            return `⚠️ ${errorDescParam || errorParam}`;
        }
        if (msg === "oauth_exchange_failed") {
            return "⚠️ Login fehlgeschlagen — bitte erneut versuchen.";
        }
        return "";
    }, [msg, preloadEmail, errorParam, errorDescParam]);

    useEffect(() => {
        if (initialNotice) setInfo(initialNotice);
    }, [initialNotice]);

    // Wenn schon eingeloggt → direkt weiter
    useEffect(() => {
        if (authLoading) return;
        if (user) {
            router.replace(nextPath);
        }
    }, [user, authLoading, router, nextPath]);

    const onLogin = useCallback(async () => {
        if (busy) return;
        setError("");
        setInfo("");
        setBusy(true);
        try {
            // Löst Email/Username + Login komplett serverseitig auf (siehe
            // actions/login.ts) -- die Email eines fremden Users landet dabei
            // nie im Browser (Migration 017: get_email_for_username ist für
            // anon/authenticated gesperrt).
            const res = await loginWithIdentifier(identifier, password);
            if (!res.ok) {
                setError(res.error);
                return;
            }

            setInfo("✅ Eingeloggt, leite weiter…");
            // Hard-Navigation statt router.replace: die Session-Cookies wurden
            // serverseitig gesetzt -- ein voller Seitenload lässt AuthProvider
            // sie beim Mount frisch aus den Cookies lesen, statt auf einen
            // client-seitigen Cache-Refresh der laufenden Supabase-Instanz zu
            // hoffen.
            window.location.assign(nextPath);
        } catch (e: unknown) {
            const m = e instanceof Error ? e.message : "Unbekannter Fehler.";
            setError(m);
        } finally {
            setBusy(false);
        }
    }, [busy, identifier, password, nextPath]);

    if (AUTH_DISABLED) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" aria-label="Login deaktiviert">
                        <header className="hostHeader">
                            <div className="hostTitleRow">
                                <h1 className="h1">Login deaktiviert</h1>
                            </div>
                            <p className="p hostSub">
                                Auth ist aktuell im Dev-Modus aus. Du kannst als Gast spielen.
                            </p>
                        </header>
                        <div className="panel">
                            <div className="previewCard">
                                <div className="actionsRow" style={{ marginTop: 14 }}>
                                    <Link href="/" className="btn btnPrimary">Zur Startseite</Link>
                                    <Link href="/join" className="btn btnSecondary">Lobby beitreten</Link>
                                </div>
                            </div>
                        </div>
                    </section>
                </div>
            </main>
        );
    }

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Anmelden">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Anmelden</h1>
                        </div>
                        <p className="p hostSub">
                            Mit Account kommen Achievements + Lifetime-Stats. Du kannst auch weiter als Gast spielen.
                        </p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel" style={{ gridColumn: "1 / -1" }}>
                            <div className="previewCard">
                                <div className="fieldRow">
                                    <label className="fieldLabel" htmlFor="identifier">
                                        Username oder E-Mail
                                    </label>
                                    <div className="fieldControl">
                                        <input
                                            id="identifier"
                                            className="input"
                                            value={identifier}
                                            onChange={(e) => setIdentifier(e.target.value)}
                                            placeholder="medo oder medo@example.de"
                                            autoComplete="username"
                                            inputMode="email"
                                        />
                                    </div>
                                </div>

                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="password">Passwort</label>
                                    <div className="fieldControl">
                                        <input
                                            id="password"
                                            className="input"
                                            type="password"
                                            value={password}
                                            onChange={(e) => setPassword(e.target.value)}
                                            onKeyDown={(e) => { if (e.key === "Enter") void onLogin(); }}
                                            placeholder="mind. 8 Zeichen"
                                            autoComplete="current-password"
                                        />
                                    </div>
                                </div>

                                {error ? <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>{error}</div> : null}
                                {info ? <div className="fieldHelp" style={{ marginTop: 10 }}>{info}</div> : null}

                                <div className="actionsRow" style={{ marginTop: 14, gap: 10, flexWrap: "wrap" }}>
                                    <button
                                        type="button"
                                        className={`btn btnPrimary ${busy ? "btnDisabled" : ""}`}
                                        onClick={() => void onLogin()}
                                        disabled={busy}
                                    >
                                        {busy ? "…" : "🔓 Einloggen"}
                                    </button>

                                    <Link href={`/register?next=${encodeURIComponent(nextPath)}`} className="btn btnSecondary">
                                        Account erstellen
                                    </Link>

                                    <Link href="/" className="btn btnSecondary">
                                        ← Als Gast spielen
                                    </Link>
                                </div>
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}

export default function LoginPage() {
    return (
        <Suspense fallback={null}>
            <LoginInner />
        </Suspense>
    );
}
