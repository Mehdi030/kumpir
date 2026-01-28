"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

type Props = {
    nextPath?: string;
    variant?: "header" | "inline";
};

export function AuthMini({ nextPath = "/", variant = "header" }: Props) {
    const supabase = getSupabaseClient();
    const [email, setEmail] = useState<string | null>(null);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        let mounted = true;

        (async () => {
            const { data } = await supabase.auth.getUser();
            if (!mounted) return;
            setEmail(data.user?.email ?? null);
            setLoading(false);
        })();

        const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
            setEmail(session?.user?.email ?? null);
            setLoading(false);
        });

        return () => {
            mounted = false;
            sub.subscription.unsubscribe();
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    async function logout() {
        await supabase.auth.signOut();
    }

    const loginHref = `/login?next=${encodeURIComponent(nextPath)}`;

    if (loading) {
        return <span className={variant === "header" ? "chip" : "fieldHelp"}>…</span>;
    }

    if (!email) {
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
      <span className={variant === "header" ? "segBtn segActive" : "btn btnSecondary"}>
        {email}
      </span>
            <button
                type="button"
                className={variant === "header" ? "segBtn" : "btn btnSecondary"}
                onClick={logout}
            >
                Abmelden
            </button>
        </div>
    );
}
