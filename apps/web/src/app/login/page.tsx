"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

function isEmailLike(v: string) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}
function normalizeUsername(v: string) {
    return v.trim().toLowerCase();
}
function normalizeEmail(v: string) {
    return v.trim().toLowerCase();
}

type Tab = "google" | "account";
type PageMode = "normal" | "check_email";

export default function LoginPage() {
    const supabase = getSupabaseClient();

    const [tab, setTab] = useState<Tab>("google");
    const [pageMode, setPageMode] = useState<PageMode>("normal");

    // ✅ Account-Login: username + email (beides Pflicht)
    const [username, setUsername] = useState("");
    const [email, setEmail] = useState("");

    const [password, setPassword] = useState("");

    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string>("");
    const [info, setInfo] = useState<string>("");

    const [nextPath, setNextPath] = useState("/host");

    useEffect(() => {
        const url = new URL(window.location.href);
        const next = url.searchParams.get("next");
        setNextPath(next && next.startsWith("/") ? next : "/host");
    }, []);

    const callbackUrl = useMemo(() => {
        if (typeof window === "undefined") return "";
        return `${window.location.origin}/auth/callback?next=${encodeURIComponent(nextPath)}`;
    }, [nextPath]);

    function resetMessages() {
        setError("");
        setInfo("");
    }

    // ✅ Handle messages from redirects
    useEffect(() => {
        const url = new URL(window.location.href);
        const msg = url.searchParams.get("m");
        const emailFromQuery = (url.searchParams.get("email") ?? "").trim();

        if (msg === "check_email") {
            setPageMode("check_email");
            setTab("account");
            setInfo(
                "Wir haben dir eine Bestätigungs-E-Mail geschickt. Bitte klicke den Link in deinem Postfach, um deinen Account zu aktivieren. Danach wirst du automatisch eingeloggt."
            );
            if (emailFromQuery && isEmailLike(emailFromQuery)) {
                setEmail(emailFromQuery);
            }
        } else if (msg === "account_created") {
            setPageMode("normal");
            setTab("account");
            setInfo("Account erstellt. Bitte bestätige zuerst deine E-Mail, danach kannst du dich anmelden.");
            if (emailFromQuery && isEmailLike(emailFromQuery)) {
                setEmail(emailFromQuery);
            }
        }

        if (msg) {
            url.searchParams.delete("m");
            if (msg !== "check_email") url.searchParams.delete("email");
            window.history.replaceState({}, "", url.toString());
        }
    }, []);

    // ✅ Wenn schon eingeloggt, direkt weiter
    useEffect(() => {
        (async () => {
            const { data } = await supabase.auth.getSession();
            if (data.session) window.location.href = nextPath;
        })();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [nextPath]);

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
        // ⚠️ Wenn du "profiles.email" nicht öffentlich machen willst, später über RPC/Edge lösen.
        const u = normalizeUsername(usernameRaw);

        const { data, error } = await supabase
            .from("profiles")
            .select("email")
            .eq("username", u)
            .maybeSingle();

        if (error) throw error;

        const out = (data?.email ?? "").trim();
        return out.length ? out : null;
    }

    async function signInAccount() {
        if (loading) return;
        setLoading(true);
        resetMessages();

        const u = username.trim();
        const e = email.trim();

        try {
            if (u.length < 3) {
                setError("Bitte Benutzername eingeben (mind. 3 Zeichen).");
                setLoading(false);
                return;
            }
            if (!isEmailLike(e)) {
                setError("Bitte eine gültige E-Mail eingeben.");
                setLoading(false);
                return;
            }
            if (password.length < 8) {
                setError("Passwort muss mindestens 8 Zeichen haben.");
                setLoading(false);
                return;
            }

            // ✅ Username -> Email aus DB
            const resolvedEmail = await resolveUsernameToEmail(u);
            if (!resolvedEmail) {
                setError("Benutzername oder E-Mail stimmt nicht.");
                setLoading(false);
                return;
            }

            // ✅ Eingegebene Email muss zur Username-Email passen
            if (normalizeEmail(resolvedEmail) !== normalizeEmail(e)) {
                setError("Benutzername und E-Mail gehören nicht zusammen.");
                setLoading(false);
                return;
            }

            const { error } = await supabase.auth.signInWithPassword({
                email: resolvedEmail,
                password,
            });
            if (error) throw error;

            window.location.href = nextPath;
        } catch (e: any) {
            const msg = (e?.message ?? "").toLowerCase();
            if (msg.includes("confirm") || msg.includes("confirmed")) {
                setError("Bitte bestätige zuerst deine E-Mail (Link im Postfach).");
            } else {
                setError(e?.message ?? "Login fehlgeschlagen.");
            }
            setLoading(false);
        }
    }

    async function forgotPassword() {
        resetMessages();

        const e = email.trim();
        if (!isEmailLike(e)) {
            setError("Für Passwort-Reset bitte deine E-Mail eingeben.");
            return;
        }

        if (loading) return;
        setLoading(true);
        try {
            const { error } = await supabase.auth.resetPasswordForEmail(e, {
                redirectTo: callbackUrl,
            });
            if (error) throw error;

            setInfo("Passwort-Reset E-Mail wurde verschickt.");
        } catch (e: any) {
            setError(e?.message ?? "Reset fehlgeschlagen.");
        } finally {
            setLoading(false);
        }
    }

    async function resendConfirmationEmail() {
        resetMessages();

        const e = email.trim();
        if (!isEmailLike(e)) {
            setError("Bitte gib deine E-Mail ein, um die Bestätigung erneut zu senden.");
            return;
        }

        if (loading) return;
        setLoading(true);
        try {
            const { error } = await supabase.auth.resend({
                type: "signup",
                email: e,
                options: { emailRedirectTo: callbackUrl },
            });
            if (error) throw error;

            setInfo("Bestätigungs-E-Mail wurde erneut verschickt.");
        } catch (e: any) {
            setError(e?.message ?? "Erneutes Senden fehlgeschlagen.");
        } finally {
            setLoading(false);
        }
    }

    // ✅ NEU: "Weiter" Button im check_email Screen
    async function continueAfterEmailConfirm() {
        resetMessages();
        if (loading) return;
        setLoading(true);
        try {
            const { data, error } = await supabase.auth.getSession();
            if (error) throw error;

            if (data.session) {
                window.location.href = nextPath;
                return;
            }

            setInfo("Noch nicht bestätigt / noch nicht eingeloggt. Bitte klicke erst den Link in der Bestätigungs-Mail und versuche es dann erneut.");
        } catch (e: any) {
            setError(e?.message ?? "Konnte Status nicht prüfen.");
        } finally {
            setLoading(false);
        }
    }

    const BackLink = ({ withArrow }: { withArrow?: boolean }) => (
        <Link href="/" className="btn btnSecondary">
            {withArrow ? "←Zurück" : "Zurück"}
        </Link>
    );

    // ✅ Registrieren als MetaPill (oben rechts)
    const RegisterPill = () => (
        <Link
            href={`/register?next=${encodeURIComponent(nextPath)}`}
            className="metaPill"
            title="Neuen Account erstellen"
            style={{ textDecoration: "none" }}
        >
            Registrieren
        </Link>
    );

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Login">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Login</h1>
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

                            {/* ✅ check_email Screen */}
                            {pageMode === "check_email" ? (
                                <div className="previewCard">
                                    <div
                                        style={{
                                            padding: 14,
                                            borderRadius: 16,
                                            background: "rgba(255,255,255,0.06)",
                                            border: "1px solid rgba(255,255,255,0.12)",
                                        }}
                                    >
                                        {/* ✅ HIER: Registrieren entfernt */}
                                        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12 }}>
                                            <div style={{ fontWeight: 900, fontSize: 16 }}>📧 E-Mail bestätigen</div>
                                        </div>

                                        <div className="fieldHelp" style={{ marginTop: 8, opacity: 0.92 }}>
                                            {info ||
                                                "Bitte bestätige deine E-Mail über den Link im Postfach. Danach wirst du automatisch eingeloggt."}
                                        </div>

                                        <div className="fieldRow" style={{ marginTop: 12 }}>
                                            <label className="fieldLabel" htmlFor="email">
                                                E-Mail
                                            </label>
                                            <div className="fieldControl">
                                                {/* ✅ nicht editierbar */}
                                                <input
                                                    id="email"
                                                    className="input"
                                                    value={email}
                                                    readOnly
                                                    disabled
                                                    aria-readonly="true"
                                                    placeholder="du@beispiel.de"
                                                    autoComplete="email"
                                                    inputMode="email"
                                                    style={{
                                                        cursor: "not-allowed",
                                                        opacity: 0.9,
                                                    }}
                                                />
                                            </div>
                                            <div className="fieldHelp" style={{ marginTop: 6, opacity: 0.85 }}>
                                                Wenn keine Mail ankam: Spam prüfen oder erneut senden.
                                            </div>
                                        </div>

                                        {/* ✅ Buttons: Weiter + Resend + Zurück */}
                                        <div className="actionsRow" style={{ marginTop: 14, gap: 10, flexWrap: "wrap" }}>
                                            <button
                                                type="button"
                                                className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                                onClick={continueAfterEmailConfirm}
                                                disabled={loading}
                                                title="Prüft, ob du nach Bestätigung schon eingeloggt bist"
                                            >
                                                {loading ? "…" : "Weiter"}
                                            </button>

                                            <button
                                                type="button"
                                                className={`btn btnSecondary ${loading ? "btnDisabled" : ""}`}
                                                onClick={resendConfirmationEmail}
                                                disabled={loading}
                                            >
                                                {loading ? "…" : "Bestätigungs-Mail erneut senden"}
                                            </button>

                                            <BackLink withArrow />
                                        </div>
                                    </div>

                                    {error && (
                                        <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>
                                            {error}
                                        </div>
                                    )}
                                    {!error && info && (
                                        <div className="fieldHelp" style={{ marginTop: 10 }}>
                                            {info}
                                        </div>
                                    )}
                                </div>
                            ) : (
                                <>
                                    {/* ✅ Tabs + Registrieren rechts (MetaPill) */}
                                    <div
                                        style={{
                                            display: "flex",
                                            alignItems: "center",
                                            justifyContent: "space-between",
                                            gap: 12,
                                            marginBottom: 12,
                                        }}
                                    >
                                        <div className="seg" style={{ marginBottom: 0 }}>
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

                                        <RegisterPill />
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
                                                    <div style={{ opacity: 0.85, fontSize: 13 }}>
                                                        Schnell • Sicher • Kein Passwort bei uns
                                                    </div>

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
                                            <form
                                                onSubmit={(e) => {
                                                    e.preventDefault();
                                                    signInAccount();
                                                }}
                                            >
                                                <div className="fieldRow">
                                                    <label className="fieldLabel" htmlFor="username">
                                                        Benutzername
                                                    </label>
                                                    <div className="fieldControl">
                                                        <input
                                                            id="username"
                                                            className="input"
                                                            value={username}
                                                            onChange={(e) => setUsername(e.target.value)}
                                                            placeholder="z.B. Medo"
                                                            autoComplete="username"
                                                        />
                                                    </div>
                                                </div>

                                                <div className="fieldRow" style={{ marginTop: 10 }}>
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
                                                        disabled={loading}
                                                        title="Passwort per E-Mail zurücksetzen"
                                                        style={{
                                                            background: "transparent",
                                                            border: "none",
                                                            padding: 0,
                                                            marginBottom: 10,
                                                            cursor: loading ? "not-allowed" : "pointer",
                                                            opacity: 0.9,
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
                                                        type="submit"
                                                        className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                                        disabled={loading}
                                                    >
                                                        Einloggen
                                                    </button>
                                                </div>
                                            </form>

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
                                </>
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
