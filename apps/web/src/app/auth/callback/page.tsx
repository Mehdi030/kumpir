"use client";

import { useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { supabase } from "@/lib/supabaseClient";

export default function AuthCallbackPage() {
    const router = useRouter();
    const searchParams = useSearchParams();

    const [status, setStatus] = useState<"loading" | "success" | "error">("loading");
    const [message, setMessage] = useState<string>("Login wird abgeschlossen…");

    useEffect(() => {
        const run = async () => {
            try {
                // Supabase OAuth liefert i.d.R. ?code=... zurück (PKCE)
                const code = searchParams.get("code");
                const error = searchParams.get("error");
                const errorDescription = searchParams.get("error_description");

                if (error) {
                    throw new Error(errorDescription ?? error);
                }

                if (!code) {
                    throw new Error("Kein OAuth-Code gefunden. Prüfe Redirect URL und Provider-Setup.");
                }

                const { error: exchangeError } = await supabase.auth.exchangeCodeForSession(code);
                if (exchangeError) throw exchangeError;

                setStatus("success");
                setMessage("Eingeloggt. Weiterleitung…");

                // Ziel nach erfolgreichem Login (Landing Page)
                router.replace("/");
            } catch (e: any) {
                setStatus("error");
                setMessage(e?.message ?? "Login fehlgeschlagen.");

                // Optional: Nach kurzer Zeit zurück zur Landing Page
                setTimeout(() => router.replace("/"), 1200);
            }
        };

        run();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    return (
        <main style={{ minHeight: "100vh", display: "grid", placeItems: "center", padding: 24 }}>
            <div
                style={{
                    maxWidth: 520,
                    width: "100%",
                    borderRadius: 16,
                    padding: 16,
                    border: "1px solid rgba(255,255,255,0.18)",
                    background: "rgba(0,0,0,0.12)",
                    color: "white",
                    boxShadow: "0 10px 30px rgba(0,0,0,0.25)",
                }}
            >
                <div style={{ fontWeight: 900, fontSize: 18 }}>
                    {status === "loading" && "Anmeldung"}
                    {status === "success" && "Erfolg"}
                    {status === "error" && "Fehler"}
                </div>

                <div style={{ marginTop: 8, opacity: 0.9 }}>{message}</div>

                <div style={{ marginTop: 12, fontSize: 12, opacity: 0.7 }}>
                    Wenn du hier hängen bleibst: Prüfe Supabase Redirect URL und Google OAuth Redirect URI.
                </div>
            </div>
        </main>
    );
}
