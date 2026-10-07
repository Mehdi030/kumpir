"use client";

import Link from "next/link";
import { useMemo } from "react";
import { useAuth } from "@/components/AuthProvider";
import { useAchievements } from "@/hooks/useAchievements";
import { Spinner } from "@/components/Spinner";
import { TIER_STYLE } from "@/lib/achievements";
import { HomeButton } from "@/components/BackButton";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

function fmtHoldTotal(ms: number) {
    if (!ms) return "—";
    const sec = Math.floor(ms / 1000);
    if (sec < 60) return `${sec}s`;
    const m = Math.floor(sec / 60);
    if (m < 60) return `${m}m ${sec % 60}s`;
    const h = Math.floor(m / 60);
    return `${h}h ${m % 60}m`;
}

function fmtFastest(ms: number | null) {
    if (ms == null) return "—";
    if (ms < 1000) return `${ms} ms`;
    return `${(ms / 1000).toFixed(2)} s`;
}

export default function AchievementsPage() {
    const { user, loading: authLoading } = useAuth();
    const { catalog, unlocked, stats, loading, error } = useAchievements(user?.id ?? null);

    const unlockedCodes = useMemo(() => new Set(unlocked.map((u) => u.achievement_code)), [unlocked]);

    if (AUTH_DISABLED) {
        return (
            <main className="container">
                <section className="card" aria-label="Achievements" style={{ maxWidth: 620, margin: "0 auto" }}>
                    <HomeButton corner />
                    <h1 className="h1">Achievements</h1>
                    <p className="p hostSub">
                        Achievements gibt&apos;s nur mit Account. Aktuell läuft das Spiel im Gast-Modus.
                    </p>
                    <Link href="/" className="btn btnSecondary">← Zur Startseite</Link>
                </section>
            </main>
        );
    }

    if (authLoading) {
        return (
            <main className="container">
                <div style={{ display: "grid", placeItems: "center", padding: 32 }}>
                    <Spinner size={28} label="Lade…" />
                </div>
            </main>
        );
    }

    if (!user) {
        return (
            <main className="container">
                <section className="card" aria-label="Achievements" style={{ maxWidth: 620, margin: "0 auto" }}>
                    <HomeButton corner />
                    <h1 className="h1">Achievements</h1>
                    <p className="p hostSub">
                        Du musst eingeloggt sein, um deine Achievements zu sehen.
                    </p>
                    <div style={{ display: "flex", gap: 10, marginTop: 14 }}>
                        <Link href="/login?next=/achievements" className="btn btnPrimary">🔓 Einloggen</Link>
                    </div>
                </section>
            </main>
        );
    }

    return (
        <main className="container">
            <section className="card" aria-label="Achievements" style={{ maxWidth: 980, margin: "0 auto" }}>
                <header className="hostHeader" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 12 }}>
                    <div>
                        <h1 className="h1">🏆 Achievements</h1>
                        <p className="p hostSub" style={{ marginTop: 4 }}>
                            {unlocked.length} von {catalog.length} freigeschaltet
                        </p>
                    </div>
                    <HomeButton />
                </header>

                {error ? <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>{error}</div> : null}

                {/* Lifetime Stats */}
                {stats ? (
                    <div className="statsGrid" style={{ marginTop: 14 }}>
                        <StatBox label="Spiele" value={stats.games_played.toString()} />
                        <StatBox label="Siege" value={stats.wins.toString()} />
                        <StatBox label="Pässe" value={stats.total_passes.toString()} />
                        <StatBox label="Clutch" value={stats.total_clutch_passes.toString()} />
                        <StatBox label="Schnellster Pass" value={fmtFastest(stats.fastest_pass_ms)} />
                        <StatBox label="Hold-Time" value={fmtHoldTotal(stats.total_hold_ms)} />
                        <StatBox label="Beste Streak" value={stats.best_survival_streak.toString()} />
                    </div>
                ) : null}

                {loading ? (
                    <div style={{ display: "grid", placeItems: "center", padding: 20 }}>
                        <Spinner size={20} label="Lade Achievements…" />
                    </div>
                ) : (
                    <div className="achievementsGrid" style={{ marginTop: 16 }}>
                        {catalog.map((a) => {
                            const got = unlockedCodes.has(a.code);
                            const style = TIER_STYLE[a.tier] ?? TIER_STYLE.bronze;
                            return (
                                <div
                                    key={a.code}
                                    className="achievementCard"
                                    style={{
                                        background: got ? style.bg : "rgba(255,255,255,0.04)",
                                        border: `1px solid ${got ? style.border : "rgba(255,255,255,0.10)"}`,
                                        boxShadow: got ? style.glow : "none",
                                        opacity: got ? 1 : 0.55,
                                        filter: got ? "none" : "grayscale(0.7)",
                                    }}
                                >
                                    <div className="achievementIcon" aria-hidden>{a.icon}</div>
                                    <div className="achievementTitle">{a.title}</div>
                                    <div className="achievementDesc">{a.description}</div>
                                    {got ? (
                                        <div className="achievementBadge">✅ Freigeschaltet</div>
                                    ) : (
                                        <div className="achievementBadge muted">🔒 Noch nicht</div>
                                    )}
                                </div>
                            );
                        })}
                    </div>
                )}
            </section>

            <style>{`
                .statsGrid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
                    gap: 10px;
                }
                .achievementsGrid {
                    display: grid;
                    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
                    gap: 14px;
                }
                .achievementCard {
                    border-radius: 18px;
                    padding: 16px;
                    display: flex;
                    flex-direction: column;
                    gap: 8px;
                    text-align: center;
                    transition: transform .18s ease, box-shadow .22s ease;
                }
                .achievementCard:hover {
                    transform: translateY(-2px);
                }
                .achievementIcon {
                    font-size: 38px;
                    line-height: 1;
                }
                .achievementTitle {
                    font-weight: 900;
                    font-size: 15px;
                    letter-spacing: 0.2px;
                }
                .achievementDesc {
                    font-size: 12px;
                    font-weight: 600;
                    opacity: 0.85;
                    line-height: 1.35;
                    min-height: 32px;
                }
                .achievementBadge {
                    margin-top: auto;
                    font-size: 11px;
                    font-weight: 950;
                    padding: 6px 10px;
                    border-radius: 999px;
                    background: rgba(0,0,0,0.32);
                    border: 1px solid rgba(255,255,255,0.10);
                    align-self: center;
                }
                .achievementBadge.muted { opacity: 0.7; }
            `}</style>
        </main>
    );
}

function StatBox({ label, value }: { label: string; value: string }) {
    return (
        <div
            style={{
                padding: 12,
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
            <div style={{ fontSize: 11, fontWeight: 800, opacity: 0.7, letterSpacing: 0.6, textTransform: "uppercase" }}>{label}</div>
            <div style={{ fontSize: 20, fontWeight: 950 }}>{value}</div>
        </div>
    );
}
