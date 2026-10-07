"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import { useProfile } from "@/hooks/useProfile";
import { useAchievements } from "@/hooks/useAchievements";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { Spinner } from "@/components/Spinner";
import { AccountStats } from "@/components/profile/AccountStats";
import { HomeButton } from "@/components/BackButton";
import { seasonKey, type ProfileStats } from "@/lib/profileStats";

/**
 * Eigene Statistik-Seite (vorher im Profil zwischen den Konto-Einstellungen): Überblick,
 * Verlauf, Musik-Werte, Gegner, Monats-Rückblick – Daten aus get_my_profile_stats (Migration 076).
 */
export default function StatsPage() {
    const { user, loading: authLoading } = useAuth();
    const { profile } = useProfile();
    const { stats, unlocked, catalog } = useAchievements(user?.id ?? null);
    const [season, setSeason] = useState(() => seasonKey(0));
    const [data, setData] = useState<ProfileStats | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");

    useEffect(() => {
        if (!user?.id) return;
        let cancel = false;
        void (async () => {
            setLoading(true);
            const { data: d, error: e } = await getSupabaseClient().rpc("get_my_profile_stats", { p_season: season });
            if (cancel) return;
            setLoading(false);
            if (e) return setError("Statistik konnte nicht geladen werden.");
            setError("");
            setData(d as ProfileStats);
        })();
        return () => {
            cancel = true;
        };
    }, [user?.id, season]);

    if (authLoading) {
        return (
            <main className="container">
                <Spinner size={28} label="Lade…" />
            </main>
        );
    }

    if (!user) {
        return (
            <main className="container">
                <div className="landingWrap">
                    <section className="card" style={{ textAlign: "center" }}>
                        <HomeButton corner />
                        <div style={{ fontSize: 44 }}>📊</div>
                        <h1 className="h1" style={{ fontSize: 40 }}>Deine Statistik</h1>
                        <p className="p hostSub" style={{ margin: "10px auto 0", maxWidth: 420 }}>
                            Mit einem Konto zählt Kumpir deine Spiele, erratene Songs und Siege.
                        </p>
                        <div className="ctaRow" style={{ marginTop: 20 }}>
                            <Link href="/login?next=/stats" className="btn btnPrimary btnXL">
                                Anmelden
                            </Link>
                            <Link href="/register?next=/stats" className="btn btnSecondary btnXL">
                                Konto erstellen
                            </Link>
                        </div>
                    </section>
                </div>
            </main>
        );
    }

    const name = profile?.displayName || profile?.username || "Du";
    const quick: [string, string][] = [
        ["Runden", String(stats?.games_played ?? 0)],
        ["Rundensiege", String(stats?.wins ?? 0)],
        ["Weitergaben", String(stats?.total_passes ?? 0)],
        ["Rettungen in letzter Sekunde", String(stats?.total_clutch_passes ?? 0)],
        ["Schnellste Weitergabe", stats?.fastest_pass_ms ? `${(stats.fastest_pass_ms / 1000).toFixed(1)} s` : "–"],
        ["Achievements", `${unlocked.length}/${catalog.length}`],
    ];

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Deine Statistik">
                    <HomeButton corner />
                    <header className="hostHeader">
                        <h1 className="h1">📊 Deine Statistik</h1>
                        <p className="p hostSub">Alles über deine Spiele, Songs und Gegner.</p>
                    </header>
                    <div className="stQuick">
                        {quick.map(([l, v]) => (
                            <div key={l} className="stQuickBox">
                                <div className="stQuickLabel">{l}</div>
                                <div className="stQuickValue">{v}</div>
                            </div>
                        ))}
                    </div>
                    {error ? <p className="fieldHelp fieldHelpError">{error}</p> : null}
                    {data ? (
                        <AccountStats data={data} username={name} season={season} onSeasonChange={setSeason} seasonLoading={loading} />
                    ) : loading ? (
                        <div style={{ display: "grid", placeItems: "center", padding: 30 }}>
                            <Spinner size={24} label="Lade Statistik…" />
                        </div>
                    ) : null}
                </section>
            </div>
            <style>{`
                .stQuick{ display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin-top: 8px; }
                .stQuickBox{ padding: 12px; border-radius: 16px; background: rgba(255,255,255,.06); border: 1px solid rgba(255,255,255,.12); display: grid; gap: 4px; text-align: center; }
                .stQuickLabel{ font-size: 10.5px; font-weight: 800; letter-spacing: .6px; text-transform: uppercase; opacity: .7; }
                .stQuickValue{ font-size: 22px; font-weight: 950; }
            `}</style>
        </main>
    );
}
