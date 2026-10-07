"use client";

import { useState } from "react";
import { useLeaderboard, type LeaderboardCategory, type LeaderboardEntry } from "@/hooks/useLeaderboard";
import { Spinner } from "@/components/Spinner";
import { SeasonBoard } from "@/components/SeasonBoard";
import { HomeButton } from "@/components/BackButton";

const AUTH_DISABLED = process.env.NEXT_PUBLIC_GUEST_ONLY === "1";

const CATEGORIES: Array<{ key: LeaderboardCategory; label: string; icon: string; unit: string; render: (e: LeaderboardEntry) => string }> = [
    {
        key: "wins",
        label: "Rundensiege",
        icon: "🏆",
        unit: "Siege",
        render: (e) => `${e.wins} (${e.win_rate_pct}%)`,
    },
    {
        key: "passes",
        label: "Pässe",
        icon: "🥔",
        unit: "Pässe",
        render: (e) => e.total_passes.toString(),
    },
    {
        key: "clutch",
        label: "Clutch-Pässe",
        icon: "⏱️",
        unit: "Clutch",
        render: (e) => e.total_clutch_passes.toString(),
    },
    {
        key: "fastest",
        label: "Schnellster Pass",
        icon: "⚡",
        unit: "ms",
        render: (e) => (e.fastest_pass_ms == null ? "—" : `${e.fastest_pass_ms} ms`),
    },
    {
        key: "streak",
        label: "Beste Survival-Streak",
        icon: "🛡️",
        unit: "Runden",
        render: (e) => e.best_survival_streak.toString(),
    },
];

export default function LeaderboardPage() {
    const [category, setCategory] = useState<LeaderboardCategory>("wins");
    const { rows, loading, error } = useLeaderboard(category, 25);

    const cfg = CATEGORIES.find((c) => c.key === category)!;

    if (AUTH_DISABLED) {
        return (
            <main className="container">
                <section className="card" aria-label="Bestenliste">
                    <HomeButton corner />
                    <h1 className="h1">Bestenliste</h1>
                    <p className="p hostSub">
                        Bestenlisten gibt&apos;s nur mit Konto. Aktuell läuft das Spiel im Gast-Modus.
                    </p>
                </section>
            </main>
        );
    }

    return (
        <main className="container">
            <section className="card" aria-label="Bestenliste" style={{ maxWidth: 880, margin: "0 auto" }}>
                <header className="hostHeader" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 12 }}>
                    <div>
                        <h1 className="h1">🏆 Bestenliste</h1>
                        <p className="p hostSub" style={{ marginTop: 4 }}>
                            Top {rows.length} weltweit · sortiert nach {cfg.label}
                        </p>
                    </div>
                    <HomeButton />
                </header>

                <SeasonBoard />

                {/* Kategorie-Switcher */}
                <div className="pillSeg" style={{ flexWrap: "wrap", marginTop: 14 }}>
                    {CATEGORIES.map((c) => (
                        <button
                            key={c.key}
                            type="button"
                            className={`pillSegBtn ${category === c.key ? "pillSegActive" : ""}`}
                            onClick={() => setCategory(c.key)}
                        >
                            {c.icon} {c.label}
                        </button>
                    ))}
                </div>

                {error ? <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>{error}</div> : null}

                {loading ? (
                    <div style={{ display: "grid", placeItems: "center", padding: 24 }}>
                        <Spinner size={24} label="Lade…" />
                    </div>
                ) : rows.length === 0 ? (
                    <div className="fieldHelp" style={{ marginTop: 16, textAlign: "center", padding: 24 }}>
                        Noch keine Daten. Spiel mit einem Account ein paar Runden — dann tauchst du hier auf.
                    </div>
                ) : (
                    <div style={{ marginTop: 14, overflowX: "auto" }}>
                        <table style={{ width: "100%", borderCollapse: "collapse" }}>
                            <thead>
                                <tr style={{ textAlign: "left", opacity: 0.7, fontSize: 12, letterSpacing: 0.6, textTransform: "uppercase" }}>
                                    <th style={{ padding: "10px 8px" }}>#</th>
                                    <th style={{ padding: "10px 8px" }}>Username</th>
                                    <th style={{ padding: "10px 8px" }}>Runden</th>
                                    <th style={{ padding: "10px 8px", textAlign: "right" }}>{cfg.unit}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {rows.map((r, idx) => (
                                    <tr
                                        key={r.user_id}
                                        style={{
                                            borderTop: "1px solid rgba(255,255,255,0.06)",
                                            background: idx < 3 ? "rgba(255,215,0,0.06)" : "transparent",
                                        }}
                                    >
                                        <td style={{ padding: "12px 8px", fontWeight: 950 }}>{rankBadge(idx + 1)}</td>
                                        <td style={{ padding: "12px 8px", fontWeight: 800 }}>{r.username}</td>
                                        <td style={{ padding: "12px 8px", opacity: 0.85 }}>{r.games_played}</td>
                                        <td style={{ padding: "12px 8px", textAlign: "right", fontWeight: 950, fontSize: 15 }}>
                                            {cfg.render(r)}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </section>
        </main>
    );
}

function rankBadge(rank: number): string {
    if (rank === 1) return "🥇";
    if (rank === 2) return "🥈";
    if (rank === 3) return "🥉";
    return String(rank);
}
