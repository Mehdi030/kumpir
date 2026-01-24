"use client";

export const dynamic = "force-dynamic";

import { useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

export default function AuthCallbackPage() {
    const router = useRouter();
    const searchParams = useSearchParams();

    const { code, error, errorDescription } = useMemo(() => {
        return {
            code: searchParams.get("code"),
            error: searchParams.get("error"),
            errorDescription: searchParams.get("error_description"),
        };
    }, [searchParams]);

    const [status, setStatus] = useState<"loading" | "success" | "error">("loading");
    const [message, setMessage] = useState("Login wird abgeschlossen…");

    useEffect(() => {
        let alive = true;

        const run = async () => {
            try {
                // ⛔ absoluter Guard: niemals beim Build
                if (typeof window === "undefined") return;

                // ✅ Supabase NUR IM BROWSER importieren
                const { supabase } = await import("@/lib/supabaseClient");

                if (error) throw new Error(errorDescription ?? error);
                if (!code) throw new Error("Kein OAuth-Code gefunden.");

                const { error: exchangeError } =
                    await supabase.auth.exchangeCodeForSession(code);

                if (exchangeError) throw exchangeError;
                if (!alive) return;

                setStatus("success");
                setMessage("Eingeloggt. Weiterleitung…");
                router.replace("/");
            } catch (e: any) {
                if (!alive) return;
                setStatus("error");
                setMessage(e?.message ?? "Login fehlgeschlagen.");
                setTimeout(() => router.replace("/"), 1200);
            }
        };

        run();
        return () => {
            alive = false;
        };
    }, [code, error, errorDescription, router]);

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
