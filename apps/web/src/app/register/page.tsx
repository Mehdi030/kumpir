"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { track } from "@/lib/track";
import { validateUsername } from "@/lib/accountSettings";
import { safeNextPath } from "@/lib/safeNext";
import { PasswordInput } from "@/components/PasswordInput";
import { registerAccount } from "@/actions/register";
import { BackButton } from "@/components/BackButton";

type UsernameStatus = "idle" | "checking" | "available" | "taken" | "error";

/** Konto nur mit Benutzername + Passwort -- keine E-Mail, keine Bestätigungsmail (actions/register.ts). */
export default function RegisterPage() {
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
        if (!uCheck.ok) return setError(`Benutzername: ${uCheck.message}`);
        if (usernameStatus === "taken") return setError("Benutzername ist bereits vergeben.");
        if (password.length < 8) return setError("Passwort muss mindestens 8 Zeichen haben.");
        if (password !== confirmPassword) return setError("Passwörter stimmen nicht überein.");

        setLoading(true);
        try {
            const res = await registerAccount(uNorm, password);
            if (!res.ok) {
                if (res.field === "username") setUsernameStatus("taken");
                setError(res.error);
                return;
            }
            track("register_success");
            setInfo("✅ Konto erstellt – du bist angemeldet.");
            // Voller Seitenaufruf, damit die frischen Anmelde-Cookies überall gelesen werden
            window.location.assign(nextPath);
        } catch {
            setError("Keine Verbindung zum Server. Bitte erneut versuchen.");
        } finally {
            setLoading(false);
        }
    }

    const statusText = !uCheck.ok
        ? username.trim()
            ? uCheck.message
            : "3–20 Zeichen"
        : usernameStatus === "checking"
          ? "prüfe…"
          : usernameStatus === "available"
            ? "✅ frei"
            : usernameStatus === "taken"
              ? "❌ vergeben"
              : usernameStatus === "error"
                ? "⚠️ prüfen fehlgeschlagen"
                : "3–20 Zeichen";

    return (
        <main className="container">
            <div className="landingWrap">
                <BackButton href={`/login?next=${encodeURIComponent(nextPath)}`} label="Zurück zum Login" />
                <section className="card" aria-label="Registrieren">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Registrieren</h1>
                        </div>
                        <p className="p hostSub">Nur Benutzername und Passwort – keine E-Mail nötig. Spielername, Avatar und mehr kannst du danach im Profil einstellen.</p>
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
                                        Benutzername
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
                                        <div className="fieldHelp" style={{ flex: "1 1 auto", whiteSpace: "nowrap", opacity: 0.9 }}>
                                            <b>{statusText}</b>
                                        </div>
                                    </div>
                                </div>

                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="password">
                                        Passwort
                                    </label>
                                    <div className="fieldControl">
                                        <PasswordInput id="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="mind. 8 Zeichen" autoComplete="new-password" />
                                    </div>
                                </div>

                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="confirmPassword">
                                        Passwort wiederholen
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
                                    <button type="submit" className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`} disabled={loading}>
                                        {loading ? "…" : "Konto erstellen"}
                                    </button>
                                    <Link href={`/login?next=${encodeURIComponent(nextPath)}`} className="btn btnSecondary">
                                        Ich habe schon ein Konto
                                    </Link>
                                </div>

                                <div className="fieldHelp" style={{ marginTop: 12, opacity: 0.9, fontSize: 13, fontWeight: 600 }}>
                                    🔐 Merk dir dein Passwort gut. Falls du es vergisst, kann ein Admin dir ein neues setzen.
                                </div>
                            </form>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
