"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useAchievements } from "@/hooks/useAchievements";
import { useProfile } from "@/hooks/useProfile";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { Spinner } from "@/components/Spinner";
import { AccountStats } from "@/components/profile/AccountStats";
import { seasonKey, type ProfileStats } from "@/lib/profileStats";
import { AccountSettings, AvatarBadge, supabaseAccountApi } from "@/components/profile/AccountSettings";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_AUTH_DISABLED === "1";


export default function ProfilePage() {
    const { profile, user, loading, refresh, savePreferences } = useProfile();
    const accountApi = useMemo(() => supabaseAccountApi(), []);
    const { unlocked, catalog } = useAchievements(user?.id ?? null);
    const supabase = getSupabaseClient();

    const [season, setSeason] = useState(() => seasonKey(0));
    const [accStats, setAccStats] = useState<ProfileStats | null>(null);
    const [accLoading, setAccLoading] = useState(false);
    const [accError, setAccError] = useState("");

    // Verlauf, Musik-Werte, Gegner und Monats-Rückblick kommen gesammelt aus EINER Funktion (Migration 076).
    useEffect(() => {
        if (!user?.id) return;
        let cancel = false;
        void (async () => {
            setAccLoading(true);
            const { data, error } = await supabase.rpc("get_my_profile_stats", { p_season: season });
            if (cancel) return;
            setAccLoading(false);
            if (error) {
                setAccError(error.message);
                return;
            }
            setAccError("");
            setAccStats(data as ProfileStats);
        })();
        return () => {
            cancel = true;
        };
    }, [supabase, user?.id, season]);


    if (AUTH_DISABLED) {
        return (
            <main className="container">
                <section className="card">
                    <h1 className="h1">Konto</h1>
                    <p className="p hostSub">Accounts sind hier gerade deaktiviert – du spielst als Gast.</p>
                    <Link href="/" className="btn btnSecondary" style={{ marginTop: 14 }}>← Startseite</Link>
                </section>
            </main>
        );
    }

    if (loading) {
        return (
            <main className="container">
                <Spinner size={28} label="Lade…" />
            </main>
        );
    }

    if (!user || !profile) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" style={{ textAlign: "center" }}>
                        <div style={{ fontSize: 44 }}>👤</div>
                        <h1 className="h1" style={{ fontSize: 40 }}>Dein Konto</h1>
                        <p className="p hostSub" style={{ margin: "10px auto 0", maxWidth: 420 }}>
                            Mit einem Konto speichert Kumpir deine Siege, Saison-Punkte und Achievements und du findest deine Freunde wieder.
                        </p>
                        <div className="ctaRow" style={{ marginTop: 20 }}>
                            <Link href="/login?next=/profile" className="btn btnPrimary btnXL">Anmelden</Link>
                            <Link href="/register?next=/profile" className="btn btnSecondary btnXL">Konto erstellen</Link>
                        </div>
                    </section>
                </div>
            </main>
        );
    }

    const name = profile.displayName || profile.username || profile.email?.split("@")[0] || "Spieler";

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card">
                    <div className="profHead">
                        <AvatarBadge emoji={profile.avatarEmoji} color={profile.avatarColor} name={name} />
                        <div className="profWho">
                            <h1 className="h1 profName">{name}</h1>
                            {profile.username ? <div className="profUser">@{profile.username}</div> : null}
                            <div className="profMail">
                                {profile.email} {profile.emailVerified ? <span className="profOk">✓ bestätigt</span> : <span className="profWarn">nicht bestätigt</span>}
                            </div>
                        </div>
                        <Link href="/" className="btn btnSecondary btnSmall profBack">
                            ← Start
                        </Link>
                    </div>

                    {accStats ? (
                        <AccountStats data={accStats} username={name} season={season} onSeasonChange={setSeason} seasonLoading={accLoading} />
                    ) : accError ? (
                        <div className="fieldHelp fieldHelpError" style={{ marginTop: 18 }}>
                            Statistik konnte nicht geladen werden: {accError}
                        </div>
                    ) : (
                        <div style={{ marginTop: 22, display: "grid", placeItems: "center" }}>
                            <Spinner size={20} label="Lade Statistik…" />
                        </div>
                    )}

                    <div className="profLinks">
                        <Link href="/achievements" className="profLink">
                            <span>🏅</span>
                            <b>Achievements</b>
                            <small>{unlocked.length} von {catalog.length || "…"} freigeschaltet</small>
                        </Link>
                        <Link href="/friends" className="profLink">
                            <span>👥</span>
                            <b>Freunde</b>
                            <small>Freunde & gemerkte Lobbies</small>
                        </Link>
                        <Link href="/leaderboard" className="profLink">
                            <span>🏆</span>
                            <b>Bestenliste</b>
                            <small>Saison & Allzeit</small>
                        </Link>
                    </div>

                    <AccountSettings profile={profile} api={accountApi} onRefresh={refresh} onSavePreferences={savePreferences} />

                    <style>{`
            .profHead{ display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
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
