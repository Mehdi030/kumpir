"use client";

import { getSupabaseClient } from "@/lib/supabaseClient";

export default function LoginPage() {
    const supabase = getSupabaseClient();

    async function signInWithGoogle() {
        const next =
            new URLSearchParams(window.location.search).get("next") ?? "/host";

        const { error } = await supabase.auth.signInWithOAuth({
            provider: "google",
            options: {
                redirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent(
                    next
                )}`,
            },
        });

        if (error) {
            console.error("[Login] OAuth error:", error);
            alert(error.message);
        }
    }

    return (
        <main className="container">
            <h1 className="h1">Login</h1>
            <button className="btn btnPrimary" onClick={signInWithGoogle}>
                Mit Google einloggen
            </button>
        </main>
    );
}
