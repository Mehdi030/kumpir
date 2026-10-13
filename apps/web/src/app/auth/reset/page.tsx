"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { PasswordInput } from "@/components/PasswordInput";
import { BackButton } from "@/components/BackButton";
import { passwordProblem, PASSWORD_HINT } from "@/lib/accountSettings";
import { useI18n } from "@/lib/i18n";

export default function ResetPasswordPage() {
    const { tr } = useI18n();
    const supabase = getSupabaseClient();
    const [pw1, setPw1] = useState("");
    const [pw2, setPw2] = useState("");
    const [loading, setLoading] = useState(false);
    const [msg, setMsg] = useState("");
    const [err, setErr] = useState("");
    const [linkInvalid, setLinkInvalid] = useState(false);

    useEffect(() => {
        // Die Sitzung aus dem Reset-Link wurde auf /auth/callback schon gesetzt.
        void supabase.auth.getSession().then((res) => {
            if (!res.data.session) setLinkInvalid(true);
        });
    }, [supabase]);

    async function onSubmit() {
        setErr("");
        setMsg("");
        const pwErr = passwordProblem(pw1);
        if (pwErr) return setErr(tr(pwErr));
        if (pw1 !== pw2) return setErr(tr("Die beiden Passwörter sind nicht gleich."));

        setLoading(true);
        try {
            const { error } = await supabase.auth.updateUser({ password: pw1 });
            if (error) throw error;
            setMsg(tr("✅ Passwort geändert – du bist angemeldet und wirst weitergeleitet…"));
            window.setTimeout(() => window.location.assign("/"), 1200);
        } catch (e: unknown) {
            const m = e instanceof Error ? e.message : "";
            setErr(/different from the old|same password/i.test(m) ? tr("Das neue Passwort muss sich vom alten unterscheiden.") : m || tr("Passwort ändern fehlgeschlagen."));
        } finally {
            setLoading(false);
        }
    }

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label={tr("Passwort zurücksetzen")}>
                    <BackButton href="/login" label={tr("Zum Login")} />
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">{tr("Neues Passwort")}</h1>
                        </div>
                        <p className="p hostSub">{tr("Wähle ein neues Passwort für dein Konto.")}</p>
                    </header>

                    {linkInvalid ? (
                        <div className="panel">
                            <div className="fieldHelp fieldHelpError">
                                {tr("Der Link ist abgelaufen oder wurde in einem anderen Browser geöffnet. Fordere einfach einen neuen an.")}
                            </div>
                            <div className="actionsRow" style={{ marginTop: 14 }}>
                                <Link href="/login?m=reset_other_device" className="btn btnPrimary">
                                    {tr("Neuen Link anfordern")}
                                </Link>
                            </div>
                        </div>
                    ) : (
                        <div className="hostGrid">
                            <div className="panel" style={{ gridColumn: "1 / -1" }}>
                                <div className="previewCard">
                                    <div className="fieldRow">
                                        <label className="fieldLabel" htmlFor="pw1">
                                            {tr("Neues Passwort")}
                                        </label>
                                        <div className="fieldControl">
                                            <PasswordInput id="pw1" value={pw1} onChange={(e) => setPw1(e.target.value)} placeholder={tr(PASSWORD_HINT)} autoComplete="new-password" />
                                        </div>
                                    </div>

                                    <div className="fieldRow" style={{ marginTop: 12 }}>
                                        <label className="fieldLabel" htmlFor="pw2">
                                            {tr("Wiederholen")}
                                        </label>
                                        <div className="fieldControl">
                                            <PasswordInput
                                                id="pw2"
                                                value={pw2}
                                                onChange={(e) => setPw2(e.target.value)}
                                                onKeyDown={(e) => {
                                                    if (e.key === "Enter") void onSubmit();
                                                }}
                                                placeholder={tr("Passwort wiederholen")}
                                                autoComplete="new-password"
                                            />
                                        </div>
                                    </div>

                                    {err ? (
                                        <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }} role="alert">
                                            {err}
                                        </div>
                                    ) : null}
                                    {msg ? <div className="fieldHelp" style={{ marginTop: 10 }}>{msg}</div> : null}

                                    <div className="actionsRow" style={{ marginTop: 14 }}>
                                        <button type="button" className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`} onClick={() => void onSubmit()} disabled={loading}>
                                            {loading ? "…" : tr("Passwort speichern")}
                                        </button>
                                    </div>
                                </div>
                            </div>
                        </div>
                    )}
                </section>
            </div>
        </main>
    );
}
