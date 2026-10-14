"use client";

import Link from "next/link";
import { AvatarEditor } from "@/components/profile/AvatarEditor";
import { useMemo } from "react";
import { useProfile } from "@/hooks/useProfile";
import { Spinner } from "@/components/Spinner";
import { AccountSettings, NameSection, supabaseAccountApi } from "@/components/profile/AccountSettings";
import { ProfileFolder } from "@/components/profile/ProfileFolder";
import { isPlaceholderEmail } from "@/lib/accountSettings";
import { HomeButton } from "@/components/BackButton";
import { useI18n } from "@/lib/i18n";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";


export default function ProfilePage() {
    const { tr } = useI18n();
    const { profile, user, loading, refresh } = useProfile();
    const accountApi = useMemo(() => supabaseAccountApi(), []);

    if (AUTH_DISABLED) {
        return (
            <main className="container">
                <section className="card">
                    <HomeButton corner />
                    <h1 className="h1">{tr("Konto")}</h1>
                    <p className="p hostSub">{tr("Konten sind hier gerade deaktiviert – du spielst als Gast.")}</p>
                </section>
            </main>
        );
    }

    if (loading) {
        return (
            <main className="container">
                <Spinner size={28} label={tr("Lade…")} />
            </main>
        );
    }

    if (!user || !profile) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" style={{ textAlign: "center" }}>
                        <HomeButton corner />
                        <div style={{ fontSize: 44 }}>👤</div>
                        <h1 className="h1" style={{ fontSize: 40 }}>{tr("Dein Konto")}</h1>
                        <p className="p hostSub" style={{ margin: "10px auto 0", maxWidth: 420 }}>
                            {tr("Mit einem Konto speichert Kumpir deine Siege, Saison-Punkte und Erfolge und du findest deine Freunde wieder.")}
                        </p>
                        <div className="ctaRow" style={{ marginTop: 20 }}>
                            <Link href="/login?next=/profile" className="btn btnPrimary btnXL">{tr("Anmelden")}</Link>
                            <Link href="/register?next=/profile" className="btn btnSecondary btnXL">{tr("Konto erstellen")}</Link>
                        </div>
                    </section>
                </div>
            </main>
        );
    }

    const name = profile.displayName || profile.username || tr("Spieler");

    return (
        <main className="container">
            <ProfileFolder active="profil" label={tr("Dein Profil")}>
                <div className="profHead">
                    <div className="profWho">
                        <div className="profKicker">{tr("Dein Profil")}</div>
                        <h1 className="h1 profName">{name}</h1>
                        {profile.username ? <div className="profUser">@{profile.username}</div> : null}
                        {profile.email && !isPlaceholderEmail(profile.email) ? (
                            <div className="profMail">
                                {profile.email} {profile.emailVerified ? <span className="profOk">{tr("✓ bestätigt")}</span> : <span className="profWarn">{tr("nicht bestätigt")}</span>}
                            </div>
                        ) : null}
                    </div>
                    <HomeButton className="profBack" />
                </div>

                {/* 1. Name */}
                <div className="profBlock">
                    <NameSection key={profile.displayName ?? ""} profile={profile} api={accountApi} onRefresh={refresh} />
                </div>

                {/* 2. Avatar */}
                <AvatarEditor name={name} initial={profile.avatarConfig} onSaved={() => void refresh()} allowGoatee={profile.username?.toLowerCase() === "achi"} allowKippa={profile.username?.toLowerCase() === "valentino"} />

                {/* 3. Konto */}
                <AccountSettings profile={profile} api={accountApi} onRefresh={refresh} />
            </ProfileFolder>

            <style>{`
            .profHead{ display:flex; align-items:flex-start; gap:16px; flex-wrap:wrap; }
            .profWho{ flex:1; min-width:180px; }
            .profKicker{ font-size: 11px; font-weight: 900; letter-spacing: 1.6px; text-transform: uppercase; opacity: .7; }
            .profName{ font-size: clamp(30px,6vw,46px) !important; margin: 2px 0 0 !important; overflow-wrap: anywhere; }
            .profUser{ font-size:14px; font-weight:700; opacity:.85; margin-top:2px; }
            .profMail{ font-size:13px; opacity:.8; margin-top:2px; word-break:break-all; }
            .profOk{ color:#8df0a6; font-weight:700; margin-left:6px; }
            .profWarn{ color:#ffd28a; font-weight:700; margin-left:6px; }
            .profBack{ align-self:flex-start; }
            .profBlock{ margin-top: 14px; padding: 14px; border-radius: 18px; background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.14); }
          `}</style>
        </main>
    );
}
