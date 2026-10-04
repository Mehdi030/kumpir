"use client";

import Link from "next/link";
import { useMemo } from "react";
import { useAuth } from "@/components/AuthProvider";
import { NotifyToggle } from "@/components/NotifyToggle";
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
            <div className={variant === "header" ? "homeAuth" : "actionsRow"}>
                <Link className={variant === "header" ? "homeLink" : "btn btnSecondary"} href={loginHref}>
                    Anmelden
                </Link>
                <Link className={variant === "header" ? "homeLink homeLinkStrong" : "btn btnSecondary"} href="/register">
                    Registrieren
                </Link>
            </div>
        );
    }

    // Achievements/Leaderboard/Friends sind Auth-only (Etappe 3). Diese
    // Links rendern nur, wenn `user` gesetzt ist -- im aktuellen Gast-Modus
    // (NEXT_PUBLIC_AUTH_DISABLED=1) kann niemand einloggen, also sind sie
    // hier faktisch tot. Direkte URL-Aufrufe der drei Routen werden
    // zusätzlich in src/proxy.ts auf "/" umgeleitet, damit niemand auf
    // einer nutzlosen "Bitte einloggen"-Seite landet.
    return (
        <div className={variant === "header" ? "homeAuth" : "actionsRow"}>
            <NotifyToggle className={variant === "header" ? "homeLink" : "btn btnSecondary btnSmall"} />
            <Link className={variant === "header" ? "homeLink" : "btn btnSecondary"} href="/achievements" title="Achievements & Stats">
                🏆
            </Link>
            <Link className={variant === "header" ? "homeLink" : "btn btnSecondary"} href="/leaderboard" title="Leaderboard">
                📊
            </Link>
            <Link className={variant === "header" ? "homeLink" : "btn btnSecondary"} href="/friends" title="Freunde & gespeicherte Lobbies">
                👥
            </Link>
            <span className={variant === "header" ? "homeLink homeUser" : "btn btnSecondary"} title={user.email ?? ""}>
                {user.email}
            </span>
            <button type="button" className={variant === "header" ? "homeLink" : "btn btnSecondary"} onClick={logout}>
                Abmelden
            </button>
        </div>
    );
}
