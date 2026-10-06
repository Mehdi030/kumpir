"use client";

import Link from "next/link";
import { useProfile } from "@/hooks/useProfile";
import { useI18n } from "@/lib/i18n";

const GUEST_ONLY = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

/**
 * Gut sichtbarer Konto-Einstieg im Hauptmenü (unter den Spiel-Knöpfen):
 * Gäste sehen "Anmelden" + "Konto erstellen", Eingeloggte ihr Konto mit Avatar,
 * Admins/Supporter zusätzlich den Weg ins Admin-Panel.
 */
export function HomeAccountBar() {
    const { user, profile, loading } = useProfile();
    const { t } = useI18n();
    if (GUEST_ONLY || loading) return <div className="homeAcc" aria-hidden style={{ minHeight: 44 }} />;

    return (
        <div className="homeAcc">
            {user ? (
                <>
                    <Link href="/profile" className="btn btnSecondary homeAccBtn">
                        <span aria-hidden>{profile?.avatarEmoji || "👤"}</span> {t("home.myAccount")}
                        {profile?.playerName ? <b className="homeAccName">· {profile.playerName}</b> : null}
                    </Link>
                    {profile?.isStaff ? (
                        <Link href="/admin" className="homeAccLink">
                            🛡️ Admin-Panel
                        </Link>
                    ) : null}
                </>
            ) : (
                <>
                    <Link href="/login?next=%2F" className="btn btnSecondary homeAccBtn">
                        👤 {t("home.login")}
                    </Link>
                    <Link href="/register?next=%2F" className="homeAccLink">
                        {t("home.register")}
                    </Link>
                    <span className="homeAccHint">{t("home.accountHint")}</span>
                </>
            )}
            <style>{`
        .homeAcc{ margin-top:14px; display:flex; gap:10px 14px; align-items:center; justify-content:center; flex-wrap:wrap; }
        .homeAccBtn{ min-height:44px; }
        .homeAccName{ font-weight:800; margin-left:4px; }
        .homeAccLink{ color:#fff; font-weight:800; text-decoration:underline; text-underline-offset:3px; }
        .homeAccHint{ flex-basis:100%; text-align:center; font-size:12px; opacity:.72; }
      `}</style>
        </div>
    );
}
