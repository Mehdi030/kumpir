"use client";

export const dynamic = "force-dynamic";

import { useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

type Status = "loading" | "success" | "error";

export default function AuthCallbackPage() {
    const router = useRouter();
    const searchParams = useSearchParams();

    const { code, oauthError, errorDescription } = useMemo(() => {
        return {
            code: searchParams.get("code"),
            oauthError: searchParams.get("error"),
            errorDescription: searchParams.get("error_description"),
        };
    }, [searchParams]);

    const [status, setStatus] = useState<Status>("loading");
    const [message, setMessage] = useState<string>("Login wird abgeschlossen…");

    useEffect(() => {
        let alive = true;

        const run = async (): Promise<void> => {
            if (typeof window === "undefined") return;

            try {
                const { getSupabaseClient } = await import("@/lib/supabaseClient");
                const supabase = getSupabaseClient();

                if (oauthError) {
                    setStatus("error");
                    setMessage(errorDescription ?? oauthError);
                    return;
                }

                if (!code) {
                    setStatus("error");
                    setMessage("Kein OAuth-Code gefunden.");
                    return;
                }

                const { error } = await supabase.auth.exchangeCodeForSession(code);
                if (error) {
                    setStatus("error");
                    setMessage(error.message);
                    return;
                }

                if (!alive) return;

                setStatus("success");
                setMessage("Eingeloggt. Weiterleitung…");
                router.replace("/");
            } catch (err: unknown) {
                if (!alive) return;

                const message =
                    err instanceof Error ? err.message : "Login fehlgeschlagen.";

                setStatus("error");
                setMessage(message);
                window.setTimeout(() => router.replace("/"), 1200);
            }
        };

        void run(); // ✅ ESLint-konform

        return () => {
            alive = false;
        };
    }, [code, oauthError, errorDescription, router]);

    return (
        <main
            style={{
                minHeight: "100vh",
                display: "grid",
                placeItems: "center",
                padding: 24,
            }}
        >
            <div
                style={{
                    maxWidth: 520,
                    width: "100%",
                    borderRadius: 16,
                    padding: 16,
                    border: "1px solid rgba(255,255,255,0.18)",
                    background: "rgba(0,0,0,0.12)",
                    color: "white",
                }}
            >
                <div style={{ fontWeight: 900, fontSize: 18 }}>
                    {status === "loading" && "Anmeldung"}
                    {status === "success" && "Erfolg"}
                    {status === "error" && "Fehler"}
                </div>

                <div style={{ marginTop: 8, opacity: 0.9 }}>{message}</div>
            </div>
        </main>
    );
}
