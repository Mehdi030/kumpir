"use client";

import Link from "next/link";
import { AvatarEditor } from "@/components/profile/AvatarEditor";
import { useMemo } from "react";
import { useAchievements } from "@/hooks/useAchievements";
import { useProfile } from "@/hooks/useProfile";
import { Spinner } from "@/components/Spinner";
import { AccountSettings, NameSection, supabaseAccountApi } from "@/components/profile/AccountSettings";
import { isPlaceholderEmail } from "@/lib/accountSettings";
import { HomeButton } from "@/components/BackButton";
import { useI18n } from "@/lib/i18n";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";


export default function ProfilePage() {
    const { tr } = useI18n();
    const { profile, user, loading, refresh, savePreferences } = useProfile();
    const accountApi = useMemo(() => supabaseAccountApi(), []);
    const { unlocked, catalog } = useAchievements(user?.id ?? null);

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

    // Reiter rechts an der Karte (wie bei einer Akte, Wunsch Mehdi 2026-10-13)
    const tabs: { href: string; icon: string; label: string; sub: string }[] = [
        { href: "/stats", icon: "📊", label: tr("Statistik"), sub: tr("Verlauf, Musik-Werte, Gegner") },
        { href: "/achievements", icon: "🏅", label: tr("Erfolge"), sub: tr("{n} von {total} freigeschaltet", { n: unlocked.length, total: catalog.length || "…" }) },
        { href: "/friends", icon: "👥", label: tr("Freunde"), sub: tr("Freunde & Anfragen") },
        { href: "/leaderboard", icon: "🏆", label: tr("Bestenliste"), sub: tr("Saison & Allzeit") },
        ...(profile.isStaff ? [{ href: "/admin", icon: "🛡️", label: tr("Admin-Panel"), sub: profile.role === "admin" ? "Admin" : "Supporter" }] : []),
    ];

    return (
        <main className="container">
            <div className="landingWrap">
                <div className="profFolder">
                    <section className="card profCard">
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

                        {/* 3. Einstellungen */}
                        <AccountSettings profile={profile} api={accountApi} onRefresh={refresh} onSavePreferences={savePreferences} />
                    </section>

                    <nav className="profTabs" aria-label={tr("Bereiche")}>
                        {tabs.map((t, i) => (
                            <Link key={t.href} href={t.href} className="profTab" style={{ ["--i" as string]: i }} title={t.sub}>
                                <span className="profTabIcon" aria-hidden>
                                    {t.icon}
                                </span>
                                <span className="profTabText">
                                    <b>{t.label}</b>
                                    <small>{t.sub}</small>
                                </span>
                            </Link>
                        ))}
                    </nav>
                </div>

                <style>{`
            .profFolder{ display: grid; grid-template-columns: minmax(0, 1fr) 190px; align-items: start; width: 100%; }
            .profCard{ position: relative; z-index: 1; }
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

            /* Reiter wie bei einer Akte: kleben rechts an der Karte */
            .profTabs{ display: grid; gap: 8px; padding-top: 34px; margin-left: -2px; }
            .profTab{ display: flex; align-items: center; gap: 10px; padding: 12px 14px 12px 16px; border-radius: 0 18px 18px 0; color: #fff; text-decoration: none;
              background: linear-gradient(90deg, rgba(60,14,8,.78), rgba(90,24,10,.62)); border: 1px solid rgba(255,255,255,.16); border-left: 0;
              box-shadow: 6px 8px 22px rgba(0,0,0,.22); transform-origin: left center;
              transition: transform .2s cubic-bezier(.22,1,.36,1), background .2s ease, padding .2s ease;
              animation: profTabIn .45s cubic-bezier(.22,1,.36,1) backwards; animation-delay: calc(var(--i, 0) * 60ms + 150ms); }
            .profTab:hover{ transform: translateX(6px); background: linear-gradient(90deg, rgba(120,36,10,.85), rgba(160,60,14,.7)); }
            .profTabIcon{ font-size: 22px; flex: none; }
            .profTabText{ display: grid; min-width: 0; line-height: 1.15; }
            .profTabText b{ font-size: 14.5px; font-weight: 900; }
            .profTabText small{ font-size: 11px; opacity: .72; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            @keyframes profTabIn{ from{ opacity: 0; transform: translateX(-24px); } }

            /* schmal: Reiter oben über der Karte */
            @media (max-width: 860px){
              .profFolder{ grid-template-columns: 1fr; }
              .profTabs{ order: -1; grid-auto-flow: column; grid-auto-columns: minmax(0, 1fr); padding: 0 10px; margin: 0 0 -2px; overflow-x: auto; }
              .profTab{ border-radius: 16px 16px 0 0; border: 1px solid rgba(255,255,255,.16); border-bottom: 0; flex-direction: column; gap: 2px; padding: 9px 6px; text-align: center; box-shadow: none; }
              .profTab:hover{ transform: translateY(-3px); }
              .profTabText small{ display: none; }
              .profTabText b{ font-size: 11.5px; }
              .profTabIcon{ font-size: 20px; }
              @keyframes profTabIn{ from{ opacity: 0; transform: translateY(12px); } }
            }
            @media (prefers-reduced-motion: reduce){ .profTab{ animation: none; } }
          `}</style>
            </div>
        </main>
    );
}
