"use client";

import { Suspense, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { Spinner } from "@/components/Spinner";
import { safeNextPath as safeNext } from "@/lib/safeNext";

function safeNextPath(v: string | null) {
    return safeNext(v, "/verified");
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
        // Fehler kommen je nach Flow als ?query oder als #fragment (z. B. abgelaufener Link)
        const hash = new URLSearchParams(typeof window !== "undefined" ? window.location.hash.replace(/^#/, "") : "");
        const errorParam = sp.get("error") ?? hash.get("error");
        const errorCode = sp.get("error_code") ?? hash.get("error_code");
        const errorDescription = sp.get("error_description") ?? hash.get("error_description");
        const isReset = next.startsWith("/auth/reset");

        (async () => {
            if (errorParam || errorCode) {
                router.replace(
                    `/login?m=auth_error&next=${encodeURIComponent(isReset ? "/" : next)}` +
                        (errorParam ? `&error=${encodeURIComponent(errorParam)}` : "") +
                        (errorCode ? `&error_code=${encodeURIComponent(errorCode)}` : "") +
                        (errorDescription ? `&error_description=${encodeURIComponent(errorDescription)}` : "")
                );
                return;
            }

            if (code) {
                const { error: exErr } = await supabase.auth.exchangeCodeForSession(code);
                if (exErr) {
                    // Häufigster Fall: Link auf einem anderen Gerät/Browser geöffnet als angefordert.
                    // Bei der Registrierung ist die E-Mail dann trotzdem schon bestätigt -> einfach anmelden.
                    const otherDevice = /code verifier|code_verifier|flow state|both auth code/i.test(exErr.message);
                    if (isReset) {
                        router.replace(`/login?m=${otherDevice ? "reset_other_device" : "link_expired"}`);
                    } else {
                        router.replace(`/login?m=${otherDevice ? "confirmed" : "link_expired"}&next=${encodeURIComponent(next)}`);
                    }
                    return;
                }
            }

            // Implicit-Flow: der Browser-Client hat #access_token beim Erzeugen
            // schon automatisch verarbeitet -- hier nur noch prüfen, ob's saß.
            const { data } = await supabase.auth.getSession();
            if (!data.session) {
                // Keine Sitzung: beim Passwort-Reset ist der Link unbrauchbar; bei der Registrierung
                // einfach anmelden (ist die E-Mail doch noch offen, bietet der Login "erneut senden" an).
                setError(isReset ? "Link abgelaufen – du wirst weitergeleitet…" : "Fast geschafft – bitte jetzt anmelden…");
                window.setTimeout(
                    () => router.replace(isReset ? "/login?m=link_expired" : `/login?m=confirmed&next=${encodeURIComponent(next)}`),
                    1200
                );
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
