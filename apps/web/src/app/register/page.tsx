"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { track } from "@/lib/track";
import { validateUsername, passwordProblem, PASSWORD_HINT } from "@/lib/accountSettings";
import { safeNextPath } from "@/lib/safeNext";
import { PasswordInput } from "@/components/PasswordInput";
import { registerAccount } from "@/actions/register";
import { HomeButton } from "@/components/BackButton";
import { useI18n } from "@/lib/i18n";

type UsernameStatus = "idle" | "checking" | "available" | "taken" | "error";

/** Konto nur mit Benutzername + Passwort -- keine E-Mail, keine Bestätigungsmail (actions/register.ts). */
export default function RegisterPage() {
    const { tr } = useI18n();
    const supabase = getSupabaseClient();

    const [username, setUsername] = useState("");
    const [password, setPassword] = useState("");
    const [confirmPassword, setConfirmPassword] = useState("");
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState("");
    const [info, setInfo] = useState("");

    const [usernameStatus, setUsernameStatus] = useState<UsernameStatus>("idle");
    const lastChecked = useRef("");

    const nextPath = useMemo(() => {
        if (typeof window === "undefined") return "/";
        return safeNextPath(new URL(window.location.href).searchParams.get("next"), "/");
    }, []);

    const uNorm = username.trim().toLowerCase();
    const uCheck = validateUsername(uNorm);

    // Verfügbarkeit prüfen, sobald man kurz aufhört zu tippen
    useEffect(() => {
        const t = setTimeout(async () => {
            if (!uCheck.ok) {
                setUsernameStatus("idle");
                lastChecked.current = "";
                return;
            }
            if (lastChecked.current === uNorm) return;
            lastChecked.current = uNorm;
            setUsernameStatus("checking");
            const { data, error: e } = await supabase.rpc("is_username_available", { p_username: uNorm });
            setUsernameStatus(e ? "error" : data ? "available" : "taken");
        }, 450);
        return () => clearTimeout(t);
    }, [uNorm, uCheck.ok, supabase]);

    async function onSubmit() {
        if (loading) return;
        setError("");
        setInfo("");
        if (!uCheck.ok) return setError(`${tr("Benutzername")}: ${tr(uCheck.message)}`);
        if (usernameStatus === "taken") return setError(tr("Dieser Benutzername ist schon vergeben."));
        const pwErr = passwordProblem(password);
        if (pwErr) return setError(tr(pwErr));
        if (password !== confirmPassword) return setError(tr("Die beiden Passwörter sind nicht gleich."));

        setLoading(true);
        try {
            const res = await registerAccount(uNorm, password);
            if (!res.ok) {
                if (res.field === "username") setUsernameStatus("taken");
                setError(tr(res.error));
                return;
            }
            track("register_success");
            setInfo(tr("✅ Konto erstellt – du bist angemeldet."));
            // Voller Seitenaufruf, damit die frischen Anmelde-Cookies überall gelesen werden
            window.location.assign(nextPath);
        } catch {
            setError(tr("Keine Verbindung zum Server. Bitte erneut versuchen."));
        } finally {
            setLoading(false);
        }
    }

    const statusText = !uCheck.ok
        ? username.trim()
            ? tr(uCheck.message)
            : tr("3–20 Zeichen")
        : usernameStatus === "checking"
          ? tr("Prüfe…")
          : usernameStatus === "available"
            ? tr("✅ frei")
            : usernameStatus === "taken"
              ? tr("❌ schon vergeben")
              : usernameStatus === "error"
                ? tr("⚠️ Konnte nicht prüfen")
                : tr("3–20 Zeichen");

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label={tr("Registrieren")}>
                    <HomeButton corner />
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">{tr("Registrieren")}</h1>
                        </div>
                        <p className="p hostSub">{tr("Nur Benutzername und Passwort – keine E-Mail nötig. Spielername, Figur und mehr kannst du danach im Profil einstellen.")}</p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel" style={{ gridColumn: "1 / -1" }}>
                            <form
                                className="previewCard"
                                onSubmit={(e) => {
                                    e.preventDefault();
                                    void onSubmit();
                                }}
                            >
                                <div className="fieldRow">
                                    <label className="fieldLabel" htmlFor="username">
                                        {tr("Benutzername")}
                                    </label>
                                    <div style={{ display: "flex", alignItems: "center", gap: 14, width: "100%" }}>
                                        <div className="fieldControl" style={{ flex: "0 1 62%" }}>
                                            <input
                                                id="username"
                                                className="input"
                                                value={username}
                                                onChange={(e) => setUsername(e.target.value)}
                                                placeholder={tr("z. B. medo")}
                                                autoComplete="username"
                                                autoCapitalize="none"
                                                autoCorrect="off"
                                                spellCheck={false}
                                                maxLength={20}
                                            />
                                        </div>
                                        <div className="fieldHelp" style={{ flex: "1 1 auto", whiteSpace: "nowrap", opacity: 0.9 }}>
                                            <b>{statusText}</b>
                                        </div>
                                    </div>
                                </div>

                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="password">
                                        {tr("Passwort")}
                                    </label>
                                    <div className="fieldControl">
                                        <PasswordInput id="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder={tr("z. B. Kartoffel7")} autoComplete="new-password" />
                                    </div>
                                    <div className={`fieldHelp ${password && passwordProblem(password) ? "fieldHelpError" : ""}`} style={{ marginTop: 6, fontSize: 12.5 }}>
                                        {password && !passwordProblem(password) ? tr("✅ Passt") : `${tr("Passwort")}: ${tr(PASSWORD_HINT)}`}
                                    </div>
                                </div>

                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="confirmPassword">
                                        {tr("Passwort wiederholen")}
                                    </label>
                                    <div className="fieldControl">
                                        <PasswordInput
                                            id="confirmPassword"
                                            value={confirmPassword}
                                            onChange={(e) => setConfirmPassword(e.target.value)}
                                            placeholder={tr("Nochmal eingeben")}
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
                                    <button type="submit" className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`} disabled={loading}>
                                        {loading ? "…" : tr("Konto erstellen")}
                                    </button>
                                    <Link href={`/login?next=${encodeURIComponent(nextPath)}`} className="btn btnSecondary">
                                        {tr("Ich habe schon ein Konto")}
                                    </Link>
                                </div>

                                <div className="fieldHelp" style={{ marginTop: 12, opacity: 0.9, fontSize: 13, fontWeight: 600 }}>
                                    {tr("🔐 Merk dir dein Passwort gut. Falls du es vergisst, kann ein Admin dir ein neues setzen.")}
                                </div>
                            </form>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
