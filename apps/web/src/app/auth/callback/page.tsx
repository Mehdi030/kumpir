"use client";

import { Suspense, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { Spinner } from "@/components/Spinner";

function safeNextPath(v: string | null) {
    if (!v) return "/verified";
    if (!v.startsWith("/")) return "/verified";
    if (v.startsWith("//")) return "/verified";
    return v;
}

/**
 * War vorher ein Server-Route-Handler (route.ts) -- funktionierte nur für
 * den PKCE-Flow (?code=...). Supabase schickt Bestätigungsmails aber
 * standardmäßig im Implicit-Flow: die Session steckt im URL-FRAGMENT
 * (#access_token=...), das der Browser nie an den Server schickt. Der
 * Server sah dort also nie einen Code, redirectete sofort (meist auf
 * /login mit "missing_code") und der Fragment-Teil ging beim Redirect
 * verloren -- Symptom: Bestätigungslink landet einfach auf localhost:3000
 * ohne eingeloggt zu sein.
 *
 * Als Client-Seite funktioniert es für BEIDE Flow-Typen: der Supabase-
 * Browser-Client (createBrowserClient, siehe lib/supabaseClient.ts) liest
 * #access_token automatisch aus der URL, sobald er erzeugt wird
 * (detectSessionInUrl, Standard an) -- wir müssen nur noch auf das
 * Ergebnis warten. Für den PKCE-Fall (?code=...) tauschen wir explizit.
 */
function AuthCallbackInner() {
    const router = useRouter();
    const sp = useSearchParams();
    const [error, setError] = useState("");

    useEffect(() => {
        const supabase = getSupabaseClient();
        const next = safeNextPath(sp.get("next"));
        const code = sp.get("code");
        const errorParam = sp.get("error");
        const errorDescription = sp.get("error_description");

        (async () => {
            if (errorParam) {
                router.replace(
                    `/login?m=auth_error&next=${encodeURIComponent(next)}&error=${encodeURIComponent(errorParam)}` +
                        (errorDescription ? `&error_description=${encodeURIComponent(errorDescription)}` : "")
                );
                return;
            }

            if (code) {
                const { error: exErr } = await supabase.auth.exchangeCodeForSession(code);
                if (exErr) {
                    router.replace(`/login?m=oauth_exchange_failed&next=${encodeURIComponent(next)}`);
                    return;
                }
            }

            // Implicit-Flow: der Browser-Client hat #access_token beim Erzeugen
            // schon automatisch verarbeitet -- hier nur noch prüfen, ob's saß.
            const { data } = await supabase.auth.getSession();
            if (!data.session) {
                setError("Bestätigung fehlgeschlagen oder Link abgelaufen.");
                window.setTimeout(() => router.replace(`/verified?m=session_missing&next=${encodeURIComponent(next)}`), 1500);
                return;
            }

            router.replace(next);
        })();
    }, [router, sp]);

    return (
        <main className="container">
            <div style={{ display: "grid", placeItems: "center", gap: 12, padding: 40 }}>
                {error ? <div className="fieldHelp fieldHelpError">{error}</div> : <Spinner size={26} label="Bestätige…" />}
            </div>
        </main>
    );
}

export default function AuthCallbackPage() {
    return (
        <Suspense fallback={null}>
            <AuthCallbackInner />
        </Suspense>
    );
}
