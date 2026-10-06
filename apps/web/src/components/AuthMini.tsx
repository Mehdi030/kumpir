"use client";

import Link from "next/link";
import { useAuth } from "@/components/AuthProvider";
import { NotifyToggle } from "@/components/NotifyToggle";
import { useProfile } from "@/hooks/useProfile";
import { useI18n } from "@/lib/i18n";

type Props = {
    nextPath?: string;
    variant?: "header" | "inline";
};

export function AuthMini({ nextPath = "/", variant = "header" }: Props) {
    const { user, loading } = useAuth();
    const { t } = useI18n();
    const { profile } = useProfile();
    const loginHref = `/login?next=${encodeURIComponent(nextPath)}`;

    if (loading) {
        return <span className={variant === "header" ? "chip" : "fieldHelp"}>…</span>;
    }

    if (!user?.email) {
        return (
            <div className={variant === "header" ? "homeAuth" : "actionsRow"}>
                <Link className={variant === "header" ? "homeLink" : "btn btnSecondary"} href={loginHref}>
                    {t("auth.login")}
                </Link>
                <Link className={variant === "header" ? "homeLink homeLinkStrong" : "btn btnSecondary"} href="/register">
                    {t("auth.register")}
                </Link>
            </div>
        );
    }

    // Eingeloggt: ein kompakter Konto-Link (alles Weitere liegt unter /profile).
    const shownName = profile?.displayName || profile?.username || user.email.split("@")[0];
    return (
        <div className={variant === "header" ? "homeAuth" : "actionsRow"}>
            <NotifyToggle className={variant === "header" ? "homeLink" : "btn btnSecondary btnSmall"} />
            <Link className={variant === "header" ? "homeLink homeLinkStrong homeUser" : "btn btnSecondary"} href="/profile" title={t("auth.account")}>
                {profile?.avatarEmoji || "👤"} {shownName}
            </Link>
        </div>
    );
}
