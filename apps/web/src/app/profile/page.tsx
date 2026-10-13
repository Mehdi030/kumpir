"use client";

import Link from "next/link";
import { PlayerAvatar } from "@/components/game/PlayerAvatar";
import { AvatarEditor } from "@/components/profile/AvatarEditor";
import { useMemo } from "react";
import { useAchievements } from "@/hooks/useAchievements";
import { useProfile } from "@/hooks/useProfile";
import { Spinner } from "@/components/Spinner";
import { AccountSettings, supabaseAccountApi } from "@/components/profile/AccountSettings";
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

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card">
                    <div className="profHead">
                        <PlayerAvatar seed={name} config={profile.avatarConfig} size={84} className="profAvatar" />
                        <div className="profWho">
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

                    <AvatarEditor name={name} initial={profile.avatarConfig} onSaved={() => void refresh()} allowGoatee={profile.username?.toLowerCase() === "achi"} />

                    <div className="profLinks">
                        <Link href="/stats" className="profLink">
                            <span>📊</span>
                            <b>{tr("Statistik")}</b>
                            <small>{tr("Verlauf, Musik-Werte, Gegner, Monats-Rückblick")}</small>
                        </Link>
                        {profile.isStaff ? (
                            <Link href="/admin" className="profLink">
                                <span>🛡️</span>
                                <b>{tr("Admin-Panel")}</b>
                                <small>{profile.role === "admin" ? "Admin" : "Supporter"} · {tr("Nutzer, Löschanträge, Lobbys")}</small>
                            </Link>
                        ) : null}
                        <Link href="/achievements" className="profLink">
                            <span>🏅</span>
                            <b>{tr("Erfolge")}</b>
                            <small>{tr("{n} von {total} freigeschaltet", { n: unlocked.length, total: catalog.length || "…" })}</small>
                        </Link>
                        <Link href="/friends" className="profLink">
                            <span>👥</span>
                            <b>{tr("Freunde")}</b>
                            <small>{tr("Freunde & gemerkte Lobbys")}</small>
                        </Link>
                        <Link href="/leaderboard" className="profLink">
                            <span>🏆</span>
                            <b>{tr("Bestenliste")}</b>
                            <small>{tr("Saison & Allzeit")}</small>
                        </Link>
                    </div>

                    <AccountSettings profile={profile} api={accountApi} onRefresh={refresh} onSavePreferences={savePreferences} />

                    <style>{`
            .profHead{ display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
            .profAvatar{ width:84px; height:84px; border-radius:50%; background: radial-gradient(circle at 40% 35%, rgba(255,226,122,.45), rgba(255,178,26,.18) 70%); box-shadow: 0 0 0 3px rgba(255,214,10,.3); }
            .profWho{ flex:1; min-width:180px; }
            .profName{ font-size: clamp(28px,6vw,40px) !important; }
            .profUser{ font-size:14px; font-weight:700; opacity:.85; margin-top:2px; }
            .profMail{ font-size:13px; opacity:.8; margin-top:2px; word-break:break-all; }
            .profOk{ color:#8df0a6; font-weight:700; margin-left:6px; }
            .profWarn{ color:#ffd28a; font-weight:700; margin-left:6px; }
            .profBack{ align-self:flex-start; }
            .profLinks{ display:grid; grid-template-columns: repeat(auto-fit, minmax(190px,1fr)); gap:10px; margin-top:14px; }
            .profLink{ display:grid; grid-template-columns:34px 1fr; column-gap:10px; padding:12px 14px; border-radius:18px; background: rgba(255,255,255,.08); border:1px solid rgba(255,255,255,.14); color:#fff; text-decoration:none; transition: background .15s ease, transform .15s ease; }
            .profLink:hover{ background: rgba(255,255,255,.15); transform: translateY(-1px); }
            .profLink span{ grid-row: span 2; font-size:24px; align-self:center; }
            .profLink small{ opacity:.7; font-size:12px; }
          `}</style>
                </section>
            </div>
        </main>
    );
}
