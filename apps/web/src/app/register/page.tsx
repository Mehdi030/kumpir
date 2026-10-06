"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { track } from "@/lib/track";
import { validateUsername } from "@/lib/accountSettings";
import { safeNextPath } from "@/lib/safeNext";
import { PasswordInput } from "@/components/PasswordInput";

function isEmailLike(v: string) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}
function normalizeUsername(v: string) {
    return v.trim().toLowerCase();
}
function normalizeEmail(v: string) {
    return v.trim().toLowerCase();
}

function isUsernameValid(u: string) {
    const v = validateUsername(u);
    return v.ok ? { ok: true, msg: "" } : { ok: false, msg: `Benutzername: ${v.message}` };
}

function isPasswordStrongEnough(pw: string) {
    if (pw.length < 8) return { ok: false, msg: "Passwort muss mindestens 8 Zeichen haben." };
    return { ok: true, msg: "" };
}

type UsernameStatus = "idle" | "checking" | "available" | "taken" | "error";

export default function RegisterPage() {
    const supabase = getSupabaseClient();

    const [username, setUsername] = useState("");
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [confirmPassword, setConfirmPassword] = useState("");

    const [loading, setLoading] = useState(false);
    const [error, setError] = useState("");
    const [info, setInfo] = useState("");

    // UX: Username availability
    const [usernameStatus, setUsernameStatus] = useState<UsernameStatus>("idle");
    const lastUsernameChecked = useRef<string>("");

    const nextPath = useMemo(() => {
        if (typeof window === "undefined") return "/";
        const url = new URL(window.location.href);
        const next = url.searchParams.get("next");
        return safeNextPath(next, "/");
    }, []);

    // ✅ Stable callback origin for email links + OAuth redirects
    const callbackUrl = useMemo(() => {
        const appUrl =
            process.env.NEXT_PUBLIC_APP_URL ||
            (typeof window !== "undefined" ? window.location.origin : "");

        if (!appUrl) return "";
        return `${appUrl}/auth/callback?next=${encodeURIComponent(nextPath)}`;
    }, [nextPath]);

    function resetMessages() {
        setError("");
        setInfo("");
    }

    async function checkUsernameAvailable(uRaw: string) {
        const u = normalizeUsername(uRaw);
        const v = isUsernameValid(u);

        if (!v.ok) {
            setUsernameStatus("idle");
            lastUsernameChecked.current = "";
            return;
        }

        // avoid spamming RPC
        if (lastUsernameChecked.current === u) return;

        lastUsernameChecked.current = u;
        setUsernameStatus("checking");

        try {
            const { data, error } = await supabase.rpc("is_username_available", { p_username: u });
            if (error) throw error;

            setUsernameStatus(data ? "available" : "taken");
        } catch {
            // For your requirement ("must choose another if can't verify"), treat as error
            setUsernameStatus("error");
        }
    }

    // Debounce: check availability after typing stops
    useEffect(() => {
        const t = setTimeout(() => {
            if (username.trim()) checkUsernameAvailable(username);
            else setUsernameStatus("idle");
        }, 450);
        return () => clearTimeout(t);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [username]);

    function validateBeforeSubmit() {
        const u = normalizeUsername(username);
        const e = normalizeEmail(email);

        const vU = isUsernameValid(u);
        if (!vU.ok) return { ok: false, msg: vU.msg };

        if (!isEmailLike(e)) return { ok: false, msg: "Bitte eine gültige E-Mail eingeben." };

        const vP = isPasswordStrongEnough(password);
        if (!vP.ok) return { ok: false, msg: vP.msg };

        if (password !== confirmPassword) return { ok: false, msg: "Passwörter stimmen nicht überein." };

        // ✅ hard requirement: must be confirmed available
        if (usernameStatus !== "available") {
            if (usernameStatus === "checking") return { ok: false, msg: "Benutzername wird noch geprüft…" };
            if (usernameStatus === "taken") return { ok: false, msg: "Benutzername ist bereits vergeben." };
            return { ok: false, msg: "Benutzername konnte nicht geprüft werden. Bitte erneut versuchen." };
        }

        return { ok: true, msg: "" };
    }

    function mapSignupErrorToMessage(raw: unknown) {
        const rawMsg =
            raw instanceof Error
                ? raw.message
                : typeof raw === "object" && raw !== null && "message" in raw
                    ? String((raw as { message?: unknown }).message ?? "")
                    : String(raw ?? "");
        const msg = rawMsg.toLowerCase();

        // Supabase typical message for email already exists
        if (msg.includes("user already registered") || msg.includes("already registered")) {
            return "Diese E-Mail ist bereits registriert. Bitte logge dich ein oder nutze eine andere E-Mail.";
        }

        // Unique constraint / duplicate username (index)
        if (msg.includes("duplicate key") || msg.includes("profiles_username_unique")) {
            return "Benutzername ist bereits vergeben. Bitte wähle einen anderen.";
        }

        if (msg.includes("rate limit") || msg.includes("seconds")) {
            return "Zu viele Versuche. Bitte kurz warten und dann erneut versuchen.";
        }
        if (msg.includes("password")) {
            return "Das Passwort ist zu schwach. Bitte mindestens 8 Zeichen verwenden.";
        }

        // Generic
        return rawMsg || "Registrierung fehlgeschlagen.";
    }

    async function onSubmit() {
        if (loading) return;

        resetMessages();

        const v = validateBeforeSubmit();
        if (!v.ok) {
            setError(v.msg);
            return;
        }

        const u = normalizeUsername(username);
        const e = normalizeEmail(email);

        setLoading(true);
        try {
            // ✅ final check right before signup (race condition protection)
            const { data: ok, error: uErr } = await supabase.rpc("is_username_available", { p_username: u });
            if (uErr) {
                setError("Konnte Benutzernamen gerade nicht prüfen. Bitte erneut versuchen.");
                return;
            }
            if (!ok) {
                setUsernameStatus("taken");
                setError("Benutzername ist bereits vergeben. Bitte wähle einen anderen.");
                return;
            }

            const { error } = await supabase.auth.signUp({
                email: e,
                password,
                options: {
                    emailRedirectTo: callbackUrl,
                    data: { username: u },
                },
            });

            if (error) throw error;
            track("register_success");

            // ✅ go to check_email screen
            const loginUrl =
                `/login?next=${encodeURIComponent(nextPath)}` +
                `&m=check_email` +
                `&email=${encodeURIComponent(e)}`;

            window.location.href = loginUrl;
        } catch (e2: unknown) {
            setError(mapSignupErrorToMessage(e2));
        } finally {
            setLoading(false);
        }
    }

    const uNorm = normalizeUsername(username);
    const uValid = isUsernameValid(uNorm).ok;

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Registrieren">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Registrieren</h1>
                        </div>
                        <p className="p hostSub">Erstelle dein Konto und sichere dir deinen Benutzernamen. Spielername, Avatar und mehr kannst du danach im Profil einstellen.</p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel" style={{ gridColumn: "1 / -1" }}>
                            <div className="previewCard">
                                {/* USERNAME */}
                                <div className="fieldRow">
                                    <label className="fieldLabel" htmlFor="username">
                                        Benutzername *
                                    </label>

                                    <div style={{ display: "flex", alignItems: "center", gap: 14, width: "100%" }}>
                                        <div className="fieldControl" style={{ flex: "0 1 62%" }}>
                                            <input
                                                id="username"
                                                className="input"
                                                value={username}
                                                onChange={(e) => setUsername(e.target.value)}
                                                placeholder="z.B. medo"
                                                autoComplete="username"
                                                autoCapitalize="none"
                                                autoCorrect="off"
                                                spellCheck={false}
                                                maxLength={20}
                                            />
                                        </div>

                                        <div className="fieldHelp" style={{ flex: "1 1 auto", textAlign: "left", whiteSpace: "nowrap", opacity: 0.9 }}>
                                            {!uValid ? (
                                                <b>{username.trim() ? (validateUsername(username) as { message?: string }).message : "3–20 Zeichen"}</b>
                                            ) : usernameStatus === "checking" ? (
                                                <b>prüfe…</b>
                                            ) : usernameStatus === "available" ? (
                                                <b style={{ opacity: 0.95 }}>✅ frei</b>
                                            ) : usernameStatus === "taken" ? (
                                                <b style={{ opacity: 0.95 }}>❌ vergeben</b>
                                            ) : usernameStatus === "error" ? (
                                                <b style={{ opacity: 0.95 }}>⚠️ prüfen fehlgeschlagen</b>
                                            ) : (
                                                <b>3–20 Zeichen</b>
                                            )}
                                        </div>
                                    </div>
                                </div>

                                {/* EMAIL */}
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
                                        <PasswordInput
                                            id="password"
                                            value={password}
                                            onChange={(e) => setPassword(e.target.value)}
                                            placeholder="mind. 8 Zeichen"
                                            autoComplete="new-password"
                                        />
                                    </div>
                                </div>

                                {/* CONFIRM */}
                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="confirmPassword">
                                        Passwort wiederholen *
                                    </label>

                                    <div className="fieldControl">
                                        <PasswordInput
                                            id="confirmPassword"
                                            value={confirmPassword}
                                            onChange={(e) => setConfirmPassword(e.target.value)}
                                            placeholder="nochmal eingeben"
                                            autoComplete="new-password"
                                        />
                                    </div>
                                </div>

                                {error ? (
                                    <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }} role="alert">
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
                                        title={usernameStatus !== "available" ? "Bitte freien Benutzernamen wählen" : "Konto erstellen"}
                                    >
                                        {loading ? "…" : "Konto erstellen"}
                                    </button>

                                    <Link href={`/login?next=${encodeURIComponent(nextPath)}`} className="btn btnSecondary">
                                        Zurück zum Login
                                    </Link>
                                </div>

                                <div className="fieldHelp" style={{ marginTop: 12, textAlign: "right", opacity: 0.9, fontSize: 13, fontWeight: 600 }}>
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
