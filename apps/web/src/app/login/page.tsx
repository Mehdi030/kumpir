"use client";

import Link from "next/link";
import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { loginWithIdentifier, resendConfirmation } from "@/actions/login";
import { PasswordInput } from "@/components/PasswordInput";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { safeNextPath as safeNext } from "@/lib/safeNext";
import { HomeButton } from "@/components/BackButton";
import { trNow, useI18n } from "@/lib/i18n";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

function safeNextPath(v: string | null) {
    return safeNext(v, "/");
}

/** Fehlercodes aus Supabase-Mail-Links in verständliche Hinweise übersetzen. */
function authErrorText(code: string | null, desc: string | null): string {
    const c = (code ?? "").toLowerCase();
    const d = (desc ?? "").toLowerCase();
    if (c.includes("otp_expired") || d.includes("expired") || d.includes("invalid")) {
        return trNow("⚠️ Der Link ist abgelaufen oder wurde schon benutzt. Melde dich an – oder fordere unten einen neuen Link an.");
    }
    return `⚠️ ${desc || code || trNow("Anmelden fehlgeschlagen.")}`;
}

function LoginInner() {
    const { tr } = useI18n();
    const router = useRouter();
    const sp = useSearchParams();
    const { user, loading: authLoading } = useAuth();

    const nextPath = safeNextPath(sp.get("next"));
    const msg = sp.get("m");
    const preloadEmail = sp.get("email") ?? "";
    const errorParam = sp.get("error");
    const errorCodeParam = sp.get("error_code");
    const errorDescParam = sp.get("error_description");

    const [identifier, setIdentifier] = useState(preloadEmail); // email oder username
    const [password, setPassword] = useState("");
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState("");
    const [info, setInfo] = useState("");

    const initialNotice = useMemo(() => {
        if (msg === "check_email" && preloadEmail) {
            return tr("📨 Bestätigungsmail an {mail} gesendet. Klick den Link, dann hier einloggen.", { mail: preloadEmail });
        }
        if (msg === "auth_error" && (errorParam || errorCodeParam || errorDescParam)) {
            return authErrorText(errorCodeParam || errorParam, errorDescParam);
        }
        if (msg === "confirmed") {
            return tr("✅ Deine E-Mail ist bestätigt. Melde dich jetzt an.");
        }
        if (msg === "reset_other_device") {
            return tr("⚠️ Den Link zum Zurücksetzen bitte im selben Browser öffnen, in dem du ihn angefordert hast – oder hier einfach einen neuen anfordern.");
        }
        if (msg === "link_expired" || msg === "oauth_exchange_failed") {
            return tr("⚠️ Der Link ist abgelaufen oder wurde schon benutzt. Melde dich an – oder fordere einen neuen Link an.");
        }
        if (msg === "account_deleted") {
            return tr("Dein Konto wurde gelöscht. Du kannst jederzeit als Gast weiterspielen.");
        }
        if (msg === "deletion_requested") {
            return tr("🗑️ Deine Löschung ist beantragt. Der Zugang ist gesperrt; ein Admin löscht das Konto endgültig. Als Gast kannst du weiterspielen.");
        }
        if (msg === "account_suspended") {
            return tr("⛔ Dieses Konto ist gesperrt. Wende dich an einen Admin, wenn das ein Irrtum ist. Als Gast kannst du weiterspielen.");
        }
        return "";
    }, [msg, preloadEmail, errorParam, errorCodeParam, errorDescParam, tr]);

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

    // Passwort vergessen: Mail mit Reset-Link (landet über /auth/callback auf /auth/reset)
    const [showReset, setShowReset] = useState(msg === "reset_other_device");
    const [needsConfirm, setNeedsConfirm] = useState(false);
    const [resendBusy, setResendBusy] = useState(false);
    const [resetEmail, setResetEmail] = useState("");
    const [resetBusy, setResetBusy] = useState(false);
    const [resetMsg, setResetMsg] = useState<{ ok: boolean; text: string } | null>(null);

    const sendReset = useCallback(async () => {
        if (resetBusy) return;
        const email = resetEmail.trim().toLowerCase();
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
            setResetMsg({ ok: false, text: tr("Bitte eine gültige E-Mail-Adresse eingeben.") });
            return;
        }
        setResetBusy(true);
        setResetMsg(null);
        const origin = process.env.NEXT_PUBLIC_APP_URL || window.location.origin;
        const { error: rErr } = await getSupabaseClient().auth.resetPasswordForEmail(email, {
            redirectTo: `${origin}/auth/callback?next=${encodeURIComponent("/auth/reset")}`,
        });
        setResetBusy(false);
        // Bewusst keine Aussage, ob die Adresse existiert (kein Konto-Ausspähen).
        setResetMsg(
            rErr && !/rate|limit|seconds/i.test(rErr.message)
                ? { ok: false, text: tr("Das hat gerade nicht geklappt. Bitte später erneut versuchen.") }
                : rErr
                  ? { ok: false, text: tr("Bitte kurz warten und dann erneut anfordern.") }
                  : { ok: true, text: tr("Wenn die Adresse bei uns registriert ist, ist eine Mail mit dem Link unterwegs.") }
        );
    }, [resetEmail, resetBusy, tr]);

    const onLogin = useCallback(async () => {
        if (busy) return;
        setError("");
        setInfo("");
        setNeedsConfirm(false);
        setBusy(true);
        try {
            // Löst Email/Username + Login komplett serverseitig auf (siehe
            // actions/login.ts) -- die Email eines fremden Users landet dabei
            // nie im Browser (Migration 017: get_email_for_username ist für
            // anon/authenticated gesperrt).
            const res = await loginWithIdentifier(identifier, password);
            if (!res.ok) {
                setError(res.error);
                if (res.code === "not_confirmed") setNeedsConfirm(true);
                return;
            }

            setInfo(tr("✅ Eingeloggt, leite weiter…"));
            // Hard-Navigation statt router.replace: die Session-Cookies wurden
            // serverseitig gesetzt -- ein voller Seitenload lässt AuthProvider
            // sie beim Mount frisch aus den Cookies lesen, statt auf einen
            // client-seitigen Cache-Refresh der laufenden Supabase-Instanz zu
            // hoffen.
            window.location.assign(nextPath);
        } catch (e: unknown) {
            const m = e instanceof Error ? e.message : tr("Unbekannter Fehler.");
            setError(m);
        } finally {
            setBusy(false);
        }
    }, [busy, identifier, password, nextPath, tr]);

    const onResend = useCallback(async () => {
        if (resendBusy) return;
        setResendBusy(true);
        const res = await resendConfirmation(identifier, window.location.origin);
        setResendBusy(false);
        if (res.ok) {
            setError("");
            setNeedsConfirm(false);
            setInfo(res.message);
        } else {
            setError(res.message);
        }
    }, [identifier, resendBusy]);

    if (AUTH_DISABLED) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" aria-label={tr("Anmelden deaktiviert")}>
                        <header className="hostHeader">
                            <div className="hostTitleRow">
                                <h1 className="h1">{tr("Anmelden deaktiviert")}</h1>
                            </div>
                            <p className="p hostSub">
                                {tr("Konten sind gerade ausgeschaltet. Du kannst als Gast spielen.")}
                            </p>
                        </header>
                        <div className="panel">
                            <div className="previewCard">
                                <div className="actionsRow" style={{ marginTop: 14 }}>
                                    <Link href="/" className="btn btnPrimary">{tr("Zur Startseite")}</Link>
                                    <Link href="/join" className="btn btnSecondary">{tr("Lobby beitreten")}</Link>
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
                <section className="card" aria-label={tr("Anmelden")}>
                    <HomeButton corner />
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">{tr("Anmelden")}</h1>
                        </div>
                        <p className="p hostSub">
                            {tr("Mit Konto speichert Kumpir deinen Verlauf, deine Musik-Werte, Erfolge und Saison-Punkte – auf jedem Gerät. Spielen geht auch ohne.")}
                        </p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel" style={{ gridColumn: "1 / -1" }}>
                            <div className="previewCard">
                                <div className="fieldRow">
                                    <label className="fieldLabel" htmlFor="identifier">
                                        {tr("Benutzername")}
                                    </label>
                                    <div className="fieldControl">
                                        <input
                                            id="identifier"
                                            className="input"
                                            value={identifier}
                                            onChange={(e) => setIdentifier(e.target.value)}
                                            placeholder={tr("z. B. medo")}
                                            autoComplete="username"
                                            autoCapitalize="none"
                                            autoCorrect="off"
                                            spellCheck={false}
                                        />
                                    </div>
                                </div>

                                <div className="fieldRow" style={{ marginTop: 10 }}>
                                    <label className="fieldLabel" htmlFor="password">{tr("Passwort")}</label>
                                    <div className="fieldControl">
                                        <PasswordInput
                                            id="password"
                                            value={password}
                                            onChange={(e) => setPassword(e.target.value)}
                                            onKeyDown={(e) => {
                                                if (e.key === "Enter") void onLogin();
                                            }}
                                            placeholder={tr("Dein Passwort")}
                                            autoComplete="current-password"
                                        />
                                    </div>
                                </div>

                                {error ? (
                                    <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }} role="alert">
                                        {tr(error)}
                                    </div>
                                ) : null}
                                {needsConfirm ? (
                                    <button type="button" className="btn btnSecondary btnSmall" style={{ marginTop: 8 }} onClick={() => void onResend()} disabled={resendBusy}>
                                        {resendBusy ? "…" : tr("📨 Bestätigungsmail erneut senden")}
                                    </button>
                                ) : null}
                                {info ? <div className="fieldHelp" style={{ marginTop: 10 }}>{tr(info)}</div> : null}

                                <div className="actionsRow" style={{ marginTop: 14, gap: 10, flexWrap: "wrap" }}>
                                    <button
                                        type="button"
                                        className={`btn btnPrimary ${busy ? "btnDisabled" : ""}`}
                                        onClick={() => void onLogin()}
                                        disabled={busy}
                                    >
                                        {busy ? "…" : tr("🔓 Einloggen")}
                                    </button>

                                    <Link href={`/register?next=${encodeURIComponent(nextPath)}`} className="btn btnSecondary">
                                        {tr("Konto erstellen")}
                                    </Link>

                                </div>

                                <div style={{ marginTop: 14 }}>
                                    <div className="fieldHelp" style={{ opacity: 0.85 }}>
                                        {tr("Passwort vergessen? Ein Admin kann dir ein neues setzen. Nur wenn dein Konto eine E-Mail-Adresse hat, geht es auch per Mail:")}
                                    </div>
                                    <button type="button" className="linkBtnLogin" onClick={() => setShowReset((v) => !v)} aria-expanded={showReset}>
                                        {tr("Link per E-Mail anfordern")}
                                    </button>
                                    {showReset ? (
                                        <div style={{ marginTop: 10, display: "grid", gap: 8 }}>
                                            <div className="fieldHelp">{tr("Gib deine E-Mail-Adresse ein – wir schicken dir einen Link zum Zurücksetzen.")}</div>
                                            <div className="fieldControl">
                                                <input
                                                    className="input"
                                                    type="email"
                                                    value={resetEmail}
                                                    onChange={(e) => setResetEmail(e.target.value)}
                                                    onKeyDown={(e) => {
                                                        if (e.key === "Enter") void sendReset();
                                                    }}
                                                    placeholder={tr("du@beispiel.de")}
                                                    autoComplete="email"
                                                />
                                                <button type="button" className="btn btnSecondary" onClick={() => void sendReset()} disabled={resetBusy}>
                                                    {resetBusy ? "…" : tr("Link senden")}
                                                </button>
                                            </div>
                                            {resetMsg ? <div className={`fieldHelp ${resetMsg.ok ? "" : "fieldHelpError"}`}>{resetMsg.text}</div> : null}
                                        </div>
                                    ) : null}
                                    <style>{`.linkBtnLogin{background:none;border:0;color:rgba(255,255,255,.85);font-weight:700;font-size:14px;text-decoration:underline;text-underline-offset:3px;cursor:pointer;padding:4px 2px}.linkBtnLogin:hover{color:#fff}`}</style>
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
