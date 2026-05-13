"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

export default function ResetPasswordPage() {
    const supabase = getSupabaseClient();
    const [pw1, setPw1] = useState("");
    const [pw2, setPw2] = useState("");
    const [loading, setLoading] = useState(false);
    const [msg, setMsg] = useState<string>("");
    const [err, setErr] = useState<string>("");

    const nextPath = useMemo(() => {
        if (typeof window === "undefined") return "/login";
        const url = new URL(window.location.href);
        const next = url.searchParams.get("next");
        return next && next.startsWith("/") ? next : "/login";
    }, []);

    useEffect(() => {
        // Supabase Recovery setzt Session automatisch via URL-Params,
        // solange die Callback/Redirect URL stimmt.
        void supabase.auth.getSession().then((res) => {
            if (!res.data.session) {
                setErr("Reset-Link ungültig oder abgelaufen. Bitte erneut anfordern.");
            }
        });
    }, [supabase]);

    async function onSubmit() {
        setErr("");
        setMsg("");

        if (pw1.length < 8) return setErr("Passwort muss mindestens 8 Zeichen haben.");
        if (pw1 !== pw2) return setErr("Passwörter stimmen nicht überein.");

        setLoading(true);
        try {
            const { error } = await supabase.auth.updateUser({ password: pw1 });
            if (error) throw error;

            setMsg("Passwort wurde geändert. Du kannst dich jetzt einloggen.");
            window.location.href = nextPath;
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : null;
            setErr(msg ?? "Passwort ändern fehlgeschlagen.");
        } finally {
            setLoading(false);
        }
    }

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Passwort zurücksetzen">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">Neues Passwort</h1>
                        </div>
                        <p className="p hostSub">Wähle ein neues Passwort für deinen Account.</p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel" style={{ gridColumn: "1 / -1" }}>
                            <div className="previewCard">
                                <div className="fieldRow">
                                    <label className="fieldLabel" htmlFor="pw1">Neues Passwort</label>
                                    <div className="fieldControl">
                                        <input id="pw1" className="input" type="password" value={pw1}
                                               onChange={(e) => setPw1(e.target.value)} placeholder="mind. 8 Zeichen" />
                                    </div>
                                </div>

                                <div className="fieldRow" style={{ marginTop: 12 }}>
                                    <label className="fieldLabel" htmlFor="pw2">Wiederholen</label>
                                    <div className="fieldControl">
                                        <input id="pw2" className="input" type="password" value={pw2}
                                               onChange={(e) => setPw2(e.target.value)} placeholder="Passwort wiederholen" />
                                    </div>
                                </div>

                                {err && <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>{err}</div>}
                                {msg && <div className="fieldHelp" style={{ marginTop: 10 }}>{msg}</div>}

                                <div className="actionsRow" style={{ marginTop: 14 }}>
                                    <button
                                        type="button"
                                        className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                        onClick={onSubmit}
                                        disabled={loading}
                                    >
                                        {loading ? "…" : "Passwort speichern"}
                                    </button>
                                </div>

                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}