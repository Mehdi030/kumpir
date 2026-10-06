"use client";

import Link from "next/link";
import { useAuth } from "@/components/AuthProvider";
import { useAchievements } from "@/hooks/useAchievements";
import { Spinner } from "@/components/Spinner";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

/**
 * Statistik-Sektion auf der Startseite. Nutzt dieselbe Datenquelle wie die
 * /achievements-Seite (player_lifetime_stats + achievements, Migration
 * 005/006, wird serverseitig automatisch bei jedem Matchende aktualisiert)
 * -- keine Platzhalter-Daten, zeigt schon jetzt echte Werte für eingeloggte
 * Spieler. Für Gäste ein Login-Hinweis statt Zahlen, die es ohne Account
 * noch nicht geben kann. Gäste sehen die Karte nicht (Anmelden steht oben rechts).
 */
export function HomeStatsSection() {
    const { user, loading: authLoading } = useAuth();
    const { stats, unlocked, catalog, loading: statsLoading } = useAchievements(AUTH_DISABLED ? null : user?.id ?? null);

    // Gäste (und der Gast-Modus) sehen hier nichts – Anmelden/Registrieren steht oben rechts.
    // Auch während des Ladens nichts zeigen, sonst blitzt bei Gästen eine leere Karte auf.
    if (AUTH_DISABLED || authLoading || !user) return null;

    const body = (
        <>
            <div className="statsSectionHead">
                <div className="stepsTitle">📊 Deine Statistik</div>
                <Link href="/achievements" className="fieldHelp" style={{ fontWeight: 900 }}>
                    Alle Achievements →
                </Link>
            </div>
            {statsLoading ? (
                <div style={{ display: "grid", placeItems: "center", padding: 16 }}>
                    <Spinner size={18} label="Lade…" />
                </div>
            ) : (
                <div className="statsGrid" style={{ marginTop: 10 }}>
                    <StatBox label="Runden" value={String(stats?.games_played ?? 0)} />
                    <StatBox label="Rundensiege" value={String(stats?.wins ?? 0)} />
                    <StatBox label="Beste Streak" value={String(stats?.best_survival_streak ?? 0)} />
                    <StatBox label="Achievements" value={`${unlocked.length}/${catalog.length}`} />
                </div>
            )}
        </>
    );

    return (
        <div className="statsSectionCard">
            {body}
            <style>{`
                .statsSectionCard{
                    margin-top: 18px;
                    padding: 16px;
                    border-radius: 18px;
                    background: rgba(0,0,0,0.16);
                    border: 1px solid rgba(255,255,255,0.10);
                }
                .statsSectionHead{
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    gap: 10px;
                    flex-wrap: wrap;
                }
                .statsGrid{
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(100px, 1fr));
                    gap: 8px;
                }
            `}</style>
        </div>
    );
}

function StatBox({ label, value }: { label: string; value: string }) {
    return (
        <div
            style={{
                padding: 10,
                borderRadius: 14,
                background: "rgba(255,255,255,0.05)",
                border: "1px solid rgba(255,255,255,0.10)",
                display: "flex",
                flexDirection: "column",
                gap: 4,
                alignItems: "center",
                justifyContent: "center",
            }}
        >
            <div style={{ fontSize: 10, fontWeight: 800, opacity: 0.7, letterSpacing: 0.6, textTransform: "uppercase" }}>{label}</div>
            <div style={{ fontSize: 18, fontWeight: 950 }}>{value}</div>
        </div>
    );
}
