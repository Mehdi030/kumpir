"use client";

import Link from "next/link";
import { useMemo } from "react";
import { useAuth } from "@/components/AuthProvider";
import { getSupabaseClient } from "@/lib/supabaseClient";

type Props = {
    nextPath?: string;
    variant?: "header" | "inline";
};

export function AuthMini({ nextPath = "/", variant = "header" }: Props) {
    const { user, loading } = useAuth();
    const supabase = useMemo(() => getSupabaseClient(), []);

    async function logout() {
        await supabase.auth.signOut();
    }

    const loginHref = `/login?next=${encodeURIComponent(nextPath)}`;

    if (loading) {
        return <span className={variant === "header" ? "chip" : "fieldHelp"}>…</span>;
    }

    if (!user?.email) {
        return (
            <div className={variant === "header" ? "seg" : "actionsRow"}>
                <Link className={variant === "header" ? "segBtn" : "btn btnSecondary"} href={loginHref}>
                    Anmelden
                </Link>
                <Link className={variant === "header" ? "segBtn" : "btn btnSecondary"} href={loginHref}>
                    Registrieren
                </Link>
            </div>
        );
    }

    return (
        <div className={variant === "header" ? "seg" : "actionsRow"}>
            <Link className={variant === "header" ? "segBtn" : "btn btnSecondary"} href="/achievements" title="Achievements & Stats">
                🏆
            </Link>
            <Link className={variant === "header" ? "segBtn" : "btn btnSecondary"} href="/leaderboard" title="Leaderboard">
                📊
            </Link>
            <span className={variant === "header" ? "segBtn segActive" : "btn btnSecondary"} title={user.email ?? ""}>
                {user.email}
            </span>
            <button type="button" className={variant === "header" ? "segBtn" : "btn btnSecondary"} onClick={logout}>
                Abmelden
            </button>
        </div>
    );
}
