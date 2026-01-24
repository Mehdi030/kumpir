"use client";

export const dynamic = "force-dynamic";

import { useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabaseClient } from "@/lib/supabaseClient";

type Status = "loading" | "success" | "error";

export default function AuthCallbackPage() {
    const router = useRouter();
    const searchParams = useSearchParams();
    const supabase = getSupabaseClient();

    const { code, oauthError, errorDescription } = useMemo(() => ({
        code: searchParams.get("code"),
        oauthError: searchParams.get("error"),
        errorDescription: searchParams.get("error_description"),
    }), [searchParams]);

    const [status, setStatus] = useState<Status>("loading");
    const [message, setMessage] = useState("Login wird abgeschlossen…");

    useEffect(() => {
        if (!code && !oauthError) return;

        const run = async () => {
            if (oauthError) {
                setStatus("error");
                setMessage(errorDescription ?? oauthError);
                return;
            }

            const { error } = await supabase.auth.exchangeCodeForSession(code!);
            if (error) {
                setStatus("error");
                setMessage(error.message);
                return;
            }

            setStatus("success");
            setMessage("Eingeloggt. Weiterleitung…");
            router.replace("/");
        };

        void run();
    }, [code, oauthError, errorDescription, router, supabase]);

    return (
        <main style={{ minHeight: "100vh", display: "grid", placeItems: "center" }}>
            <div style={{ color: "white" }}>
                <strong>{status}</strong>
                <div>{message}</div>
            </div>
        </main>
    );
}
