"use client";

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

<<<<<<< HEAD
    const nextPath = useMemo(() => {
        if (typeof window === "undefined") return "/host";
=======
    // ✅ account_created message handling (from /register redirect)
    useEffect(() => {
        const url = new URL(window.location.href);
        const msg = url.searchParams.get("m");

        if (msg === "account_created") {
            setTab("account");
            setIdMode("email");
            setInfo("Account erstellt. Bitte logge dich jetzt ein.");

            // optional: URL clean-up
            // url.searchParams.delete("m");
            // window.history.replaceState({}, "", url.toString());
        }
    }, []);

    const [nextPath, setNextPath] = useState("/host");
    useEffect(() => {
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
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
<<<<<<< HEAD
    }, []);
=======
    }, [nextPath]);

    const idLabel =
        idMode === "username" ? "Benutzername" : idMode === "email" ? "E-Mail" : "Telefon";

    const idPlaceholder =
        idMode === "username" ? "Mehdi" : idMode === "email" ? "mehdi@email.de" : "01761234567";

    function resetMessages() {
        setError("");
        setInfo("");
    }
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)

    async function signInWithGoogle() {
        if (loading) return;
        setLoading(true);
<<<<<<< HEAD
        setError("");
        setInfo("");
=======
        resetMessages();
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)

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

<<<<<<< HEAD
    async function signInEmail() {
=======
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
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
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

<<<<<<< HEAD
=======
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
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
            if (error) throw error;

            window.location.href = nextPath;
        } catch (e: any) {
            setError(e?.message ?? "Login fehlgeschlagen.");
            setLoading(false);
        }
    }

<<<<<<< HEAD
    async function signUpEmail() {
=======
    async function forgotPassword() {
        resetMessages();

        const id = identifier.trim();
        if (!isEmailLike(id)) {
            setError("Für Passwort-Reset bitte eine E-Mail auswählen und eingeben.");
            return;
        }

        if (loading) return;
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
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
<<<<<<< HEAD
            <Link href="/" className="brandLogo" aria-label="Zur Landing Page">
                <Image src="/logo.png" alt="Kumpir Maskottchen" width={400} height={400} priority className="brandLogoImg" />
            </Link>

=======
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
            <div className="landingWrap">
                <section className="card" aria-label="Login">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Login</h1>

<<<<<<< HEAD
                            <span className="chip" title="Für Lobby-Hosting erforderlich" aria-label="Erforderlich">
                <span
                    className="chipDot"
                    aria-hidden
                    style={{ background: "rgba(34,211,238,.92)", boxShadow: "0 0 0 3px rgba(34,211,238,.18)" }}
                />
                Erforderlich
              </span>
=======
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
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
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
<<<<<<< HEAD
                                <div className="previewCard" style={{ marginTop: 0 }}>
                                    <div className="previewTop">
                                        <div className="avatar" aria-hidden>
                                            G
=======
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
                                            (e.currentTarget as HTMLDivElement).style.background =
                                                "rgba(255,255,255,0.075)";
                                            (e.currentTarget as HTMLDivElement).style.transform = "scale(1.01)";
                                        }}
                                        onMouseLeave={(e) => {
                                            (e.currentTarget as HTMLDivElement).style.background =
                                                "rgba(255,255,255,0.06)";
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
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
                                        </div>
                                        <div className="previewMeta">
                                            <div className="previewName">Google</div>
                                            <div className="previewSub">Schnell • Sicher • Kein Passwort bei uns gespeichert</div>
                                        </div>
                                    </div>

<<<<<<< HEAD
=======
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

                                        <RegisterLink
                                            className="btn btnSecondary"
                                            style={{ paddingInline: 14, paddingBlock: 10 }}
                                        />
                                    </div>

                                    {/* ✅ Nur im Google-Tab */}
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
                                                autoComplete={
                                                    idMode === "email" ? "email" : idMode === "phone" ? "tel" : "username"
                                                }
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

>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
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

<<<<<<< HEAD
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
=======
                                    <div style={{ marginTop: 12 }}>
                                        <BackLink withArrow />
>>>>>>> a2f70f4 (feat(ui): Login und reset angepasst)
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
