"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

function safeNextPath(v: string | null) {
    if (!v) return "/host";
    if (!v.startsWith("/")) return "/host";
    if (v.startsWith("//")) return "/host";
    return v;
}

export default function VerifiedPage() {
    const supabase = getSupabaseClient();

    const [loading, setLoading] = useState(false);
    const [info, setInfo] = useState<string>("");
    const [error, setError] = useState<string>("");

    const nextPath = useMemo(() => {
        if (typeof window === "undefined") return "/host";
        const url = new URL(window.location.href);
        return safeNextPath(url.searchParams.get("next"));
    }, []);

    async function checkAndContinue() {
        setError("");
        setInfo("");

        if (loading) return;
        setLoading(true);

        try {
            const { data, error } = await supabase.auth.getSession();
            if (error) throw error;

            if (data.session) {
                window.location.href = nextPath;
                return;
            }

            // Kein Session-Cookie gesetzt -> häufig Safari/Mail-App/anderer Browser
            setInfo(
                "Deine E-Mail ist bestätigt. Falls du noch nicht eingeloggt bist: Öffne den Bestätigungslink im selben Browser, in dem du dich registriert hast, oder gehe zum Login und melde dich an."
            );
        } catch (e: any) {
            setError(e?.message ?? "Konnte Status nicht prüfen.");
        } finally {
            setLoading(false);
        }
    }

    // Auto-check beim Laden: wenn Session da, direkt weiter
    useEffect(() => {
        checkAndContinue();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Bestätigt">
                    <header className="hostHeader">
                        <div className="hostTitleRow">
                            <h1 className="h1">✅ Bestätigt</h1>
                        </div>
                        <p className="p hostSub">
                            Deine E-Mail wurde bestätigt. Wenn du schon eingeloggt bist, leiten wir dich automatisch weiter.
                        </p>
                    </header>

                    <div className="hostGrid">
                        <div className="panel" style={{ gridColumn: "1 / -1" }}>
                            <div className="previewCard">
                                <div className="actionsRow" style={{ gap: 10, flexWrap: "wrap" }}>
                                    <button
                                        type="button"
                                        className={`btn btnPrimary ${loading ? "btnDisabled" : ""}`}
                                        onClick={checkAndContinue}
                                        disabled={loading}
                                        title="Prüft, ob du bereits eingeloggt bist"
                                    >
                                        {loading ? "…" : "Weiter"}
                                    </button>

                                    <Link href={`/login?next=${encodeURIComponent(nextPath)}`} className="btn btnSecondary">
                                        Zum Login
                                    </Link>

                                    <Link href="/" className="btn btnSecondary">
                                        Startseite
                                    </Link>
                                </div>

                                {error ? (
                                    <div className="fieldHelp fieldHelpError" style={{ marginTop: 12 }}>
                                        {error}
                                    </div>
                                ) : null}

                                {info ? (
                                    <div className="fieldHelp" style={{ marginTop: 12, opacity: 0.9 }}>
                                        {info}
                                    </div>
                                ) : (
                                    <div className="fieldHelp" style={{ marginTop: 12, opacity: 0.9 }}>
                                        Tipp: Auf iPhone/Safari kann es passieren, dass die Mail-App den Link in einem anderen Kontext öffnet. Dann
                                        einfach „Zum Login“ drücken und normal einloggen.
                                    </div>
                                )}
                            </div>
                        </div>
                    </div>
                </section>
            </div>
        </main>
    );
}
