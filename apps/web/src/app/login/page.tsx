"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
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

export default function LoginPage() {
    const supabase = getSupabaseClient();

    const [tab, setTab] = useState<"google" | "account">("google");
    const [idMode, setIdMode] = useState<"username" | "email" | "phone">("username");

    const [identifier, setIdentifier] = useState("");
    const [password, setPassword] = useState("");

    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string>("");
    const [info, setInfo] = useState<string>("");

    const [nextPath, setNextPath] = useState("/host");

    function resetMessages() {
        setError("");
        setInfo("");
    }

    // read query params: next + account_created message
    useEffect(() => {
        const url = new URL(window.location.href);

        const next = url.searchParams.get("next");
        setNextPath(next && next.startsWith("/") ? next : "/host");

        const msg = url.searchParams.get("m");
        if (msg === "account_created") {
            setTab("account");
            setIdMode("email");
            setInfo("Account erstellt. Bitte logge dich jetzt ein.");

            // optional: URL clean-up
            url.searchParams.delete("m");
            window.history.replaceState({}, "", url.toString());
        }
    }, []);

    const callbackUrl = useMemo(() => {
        if (typeof window === "undefined") return "";
        return `${window.location.origin}/auth/callback?next=${encodeURIComponent(nextPath)}`;
    }, [nextPath]);

    // if already logged in -> redirect
    useEffect(() => {
        (async () => {
            const { data } = await supabase.auth.getSession();
            if (data.session) window.location.href = nextPath;
        })();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [nextPath]);

    const idLabel = idMode === "username" ? "Benutzername" : idMode === "email" ? "E-Mail" : "Telefon";
    const idPlaceholder =
        idMode === "username" ? "Mehdi" : idMode === "email" ? "mehdi@email.de" : "+491761234567";

    async function signInWithGoogle() {
        if (loading) return;
        setLoading(true);
        resetMessages();

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

    async function resolveUsernameToEmail(usernameRaw: string) {
        const u = normalizeUsername(usernameRaw);

        const { data, error } = await supabase
            .from("profiles")
            .select("email")
            .eq("username", u)
            .maybeSingle();

        if (error) throw error;

        const email = (data?.email ?? "").trim();
        return email.length ? email : null;
    }

    async function signInAccount() {
        if (loading) return;
        setLoading(true);
        resetMessages();

        const id = identifier.trim();

        try {
            if (id.length < 3) {
                setError("Bitte Wert eingeben.");
                setLoading(false);
                return;
            }
            if (password.length < 8) {
                setError("Passwort muss mindestens 8 Zeichen haben.");
                setLoading(false);
                return;
            }

            if (idMode === "email") {
                if (!isEmailLike(id)) {
                    setError("Bitte eine gültige E-Mail eingeben.");
                    setLoading(false);
                    return;
                }
                const { error } = await supabase.auth.signInWithPassword({ email: id, password });
                if (error) throw error;
                window.location.href = nextPath;
                return;
            }

            if (idMode === "phone") {
                if (!isPhoneLike(id)) {
                    setError("Bitte eine gültige Telefonnummer eingeben.");
                    setLoading(false);
                    return;
                }
                const { error } = await supabase.auth.signInWithPassword({ phone: id, password });
                if (error) throw error;
                window.location.href = nextPath;
                return;
            }

            // username -> email -> signIn
            const email = await resolveUsernameToEmail(id);
            if (!email) {
                setError("Login fehlgeschlagen.");
                setLoading(false);
                return;
            }

            const { error } = await supabase.auth.signInWithPassword({ email, password });
            if (error) throw error;

            window.location.href = nextPath;
        } catch (e: any) {
            setError(e?.message ?? "Login fehlgeschlagen.");
            setLoading(false);
        }
    }

    async function forgotPassword() {
        resetMessages();

        const id = identifier.trim();
        if (idMode !== "email" || !isEmailLike(id)) {
            setError("Für Passwort-Reset bitte E-Mail auswählen und eine gültige Adresse eingeben.");
            return;
        }

        if (loading) return;
        setLoading(true);
        try {
            const { error } = await supabase.auth.resetPasswordForEmail(id, { redirectTo: callbackUrl });
            if (error) throw error;
            setInfo("Passwort-Reset E-Mail wurde verschickt.");
        } catch (e: any) {
            setError(e?.message ?? "Reset fehlgeschlagen.");
        } finally {
            setLoading(false);
        }
    }

    const RegisterLink = ({
                              className,
                              style,
                          }: {
        className: string;
        style?: React.CSSProperties;
    }) => (
        <Link
            href={`/register?next=${encodeURIComponent(nextPath)}`}
            className={className}
            title="Erstellt einen neuen Account"
            style={style}
        >
            Registrieren
        </Link>
    );

    const BackLink = ({ withArrow }: { withArrow?: boolean }) => (
        <Link href="/" className="btn btnSecondary">
            {withArrow ? "←Zurück" : "Zurück"}
        </Link>
    );

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Login">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Login</h1>

                            <span
                                className="chip"
                                title="Für Lobby-Hosting erforderlich"
                                style={{ animation: "metaPulse 2.8s ease-in-out infinite" }}
                            >
                <span
                    className="chipDot"
                    aria-hidden
                    style={{
                        background: "rgba(34,211,238,.95)",
                        boxShadow: "0 0 0 4px rgba(34,211,238,.25)",
                    }}
                />
                Erforderlich
              </span>
                        </div>

                        <p className="p hostSub">
                            Melde dich an, damit du deine Lobby kontrollieren und speichern kannst.
                        </p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel">
                            <div className="panelHead">
                                <div className="panelTitle">Anmelden</div>
                            </div>

                            <div className="seg" style={{ marginBottom: 12 }}>
                                <button
                                    type="button"
                                    className={`segBtn ${tab === "google" ? "segActive" : ""}`}
                                    onClick={() => {
                                        resetMessages();
                                        setTab("google");
                                    }}
                                    disabled={loading}
                                >
                                    Google
                                </button>
                                <button
                                    type="button"
                                    className={`segBtn ${tab === "account" ? "segActive" : ""}`}
                                    onClick={() => {
                                        resetMessages();
                                        setTab("account");
                                    }}
                                    disabled={loading}
                                >
                                    Account
                                </button>
                            </div>

                            {tab === "google" ? (
                                <div className="previewCard">
                                    <div
                                        style={{
                                            display: "flex",
                                            alignItems: "center",
                                            gap: 14,
                                            padding: 14,
                                            borderRadius: 16,
                                            background: "rgba(255,255,255,0.06)",
                                            border: "1px solid rgba(255,255,255,0.12)",
                                            transition: "transform .18s ease, background .18s ease",
                                        }}
                                        onMouseEnter={(e) => {
                                            (e.currentTarget as HTMLDivElement).style.background = "rgba(255,255,255,0.075)";
                                            (e.currentTarget as HTMLDivElement).style.transform = "scale(1.01)";
                                        }}
                                        onMouseLeave={(e) => {
                                            (e.currentTarget as HTMLDivElement).style.background = "rgba(255,255,255,0.06)";
                                            (e.currentTarget as HTMLDivElement).style.transform = "scale(1)";
                                        }}
                                    >
                                        <div
                                            style={{
                                                width: 40,
                                                height: 40,
                                                borderRadius: 12,
                                                display: "grid",
                                                placeItems: "center",
                                                background: "#fff",
                                            }}
                                        >
                                            <img src="/google.svg" alt="Google" width={20} height={20} />
                                        </div>

                                        <div style={{ minWidth: 0 }}>
                                            <div style={{ fontWeight: 800 }}>Google</div>
                                            <div style={{ opacity: 0.85, fontSize: 13 }}>Schnell • Sicher • Kein Passwort bei uns</div>

                                            <div className="fieldHelp" style={{ marginTop: 6, opacity: 0.88 }}>
                                                🔐 Wir speichern keine Passwörter • 🛡️ Standard-Login über Google
                                            </div>
                                        </div>
                                    </div>

                                    <div className="actionsRow" style={{ marginTop: 12, gap: 10 }}>
                                        <button
                                            type="button"
                                            className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                            onClick={signInWithGoogle}
                                            disabled={loading}
                                            style={{ paddingInline: 16, paddingBlock: 10 }}
                                        >
                                            {loading ? "Weiterleiten…" : "Mit Google anmelden"}
                                        </button>

                                        <RegisterLink className="btn btnSecondary" style={{ paddingInline: 14, paddingBlock: 10 }} />
                                    </div>

                                    <div className="fieldHelp" style={{ marginTop: 10, opacity: 0.9 }}>
                                        Zum <b>Mitspielen</b> brauchst du keinen Account.
                                    </div>

                                    <div style={{ marginTop: 12 }}>
                                        <BackLink />
                                    </div>
                                </div>
                            ) : (
                                <div className="previewCard">
                                    <div style={{ display: "flex", gap: 8, marginBottom: 10, flexWrap: "wrap" }}>
                                        <button
                                            type="button"
                                            className={`segBtn ${idMode === "username" ? "segActive" : ""}`}
                                            onClick={() => {
                                                resetMessages();
                                                setIdMode("username");
                                            }}
                                            disabled={loading}
                                            style={{ paddingInline: 12, paddingBlock: 8 }}
                                        >
                                            Benutzername
                                        </button>

                                        <button
                                            type="button"
                                            className={`segBtn ${idMode === "email" ? "segActive" : ""}`}
                                            onClick={() => {
                                                resetMessages();
                                                setIdMode("email");
                                            }}
                                            disabled={loading}
                                            style={{ paddingInline: 12, paddingBlock: 8 }}
                                        >
                                            E-Mail
                                        </button>

                                        <button
                                            type="button"
                                            className={`segBtn ${idMode === "phone" ? "segActive" : ""}`}
                                            onClick={() => {
                                                resetMessages();
                                                setIdMode("phone");
                                            }}
                                            disabled={loading}
                                            style={{ paddingInline: 12, paddingBlock: 8 }}
                                        >
                                            Telefon
                                        </button>
                                    </div>

                                    <div className="fieldRow">
                                        <label className="fieldLabel" htmlFor="identifier">
                                            {idLabel}
                                        </label>
                                        <div className="fieldControl">
                                            <input
                                                id="identifier"
                                                className="input"
                                                value={identifier}
                                                onChange={(e) => setIdentifier(e.target.value)}
                                                placeholder={idPlaceholder}
                                                autoComplete={idMode === "email" ? "email" : idMode === "phone" ? "tel" : "username"}
                                                inputMode={idMode === "email" ? "email" : idMode === "phone" ? "tel" : "text"}
                                            />
                                        </div>
                                    </div>

                                    <div
                                        style={{
                                            display: "flex",
                                            alignItems: "flex-end",
                                            justifyContent: "space-between",
                                            gap: 10,
                                            marginTop: 10,
                                        }}
                                    >
                                        <div style={{ flex: 1 }}>
                                            <div className="fieldRow" style={{ margin: 0 }}>
                                                <label className="fieldLabel" htmlFor="password">
                                                    Passwort
                                                </label>
                                                <div className="fieldControl">
                                                    <input
                                                        id="password"
                                                        className="input"
                                                        type="password"
                                                        value={password}
                                                        onChange={(e) => setPassword(e.target.value)}
                                                        placeholder="mind. 8 Zeichen"
                                                        autoComplete="current-password"
                                                    />
                                                </div>
                                            </div>
                                        </div>

                                        <button
                                            type="button"
                                            onClick={forgotPassword}
                                            disabled={loading || idMode !== "email"}
                                            title="Nur möglich, wenn E-Mail ausgewählt ist"
                                            style={{
                                                background: "transparent",
                                                border: "none",
                                                padding: 0,
                                                marginBottom: 10,
                                                cursor: loading || idMode !== "email" ? "not-allowed" : "pointer",
                                                opacity: idMode !== "email" ? 0.55 : 0.9,
                                                color: "rgba(255,255,255,.85)",
                                                textDecoration: "underline",
                                                fontSize: 12,
                                                whiteSpace: "nowrap",
                                            }}
                                        >
                                            Passwort vergessen?
                                        </button>
                                    </div>

                                    <div className="actionsRow" style={{ marginTop: 14 }}>
                                        <button
                                            type="button"
                                            className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                            onClick={signInAccount}
                                            disabled={loading}
                                        >
                                            Einloggen
                                        </button>

                                        <RegisterLink className="btn btnAccent" />
                                    </div>

                                    <div style={{ marginTop: 12 }}>
                                        <BackLink withArrow />
                                    </div>
                                </div>
                            )}

                            {error && (
                                <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>
                                    {error}
                                </div>
                            )}
                            {info && (
                                <div className="fieldHelp" style={{ marginTop: 10 }}>
                                    {info}
                                </div>
                            )}
                        </div>

                        <div className="panel panelAlt">
                            <div className="panelHead">
                                <div className="panelTitle">Warum Login?</div>
                            </div>

                            <div className="previewCard">
                                <ul style={{ margin: 0, paddingLeft: 18, lineHeight: 1.4 }}>
                                    <li>
                                        <b>Lobby-Kontrolle</b> (Start, Ablauf, Einstellungen)
                                    </li>
                                    <li>
                                        <b>Statistiken</b> für später
                                    </li>
                                    <li>
                                        <b>Einstellungen</b> bleiben gespeichert
                                    </li>
                                </ul>
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}