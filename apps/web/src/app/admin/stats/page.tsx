"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useAuth } from "@/components/AuthProvider";
import { Spinner } from "@/components/Spinner";
import { AdminAnalytics } from "@/components/admin/AdminAnalytics";

type Stats = {
    lobbies: {
        totalEver: number;
        activeNow: number;
        last24h: number;
        byMode: Record<string, number>;
        bySpeed: Record<string, number>;
    };
    players: {
        totalRows: number;
        botRows: number;
        activeRows: number;
    };
    matches: {
        finished: number;
        avgPlayers: number | null;
        avgDurationSec: number | null;
    };
    social: {
        registeredUsers: number;
        acceptedFriendships: number;
        savedLobbies: number;
    };
    content: {
        activeTopics: number;
    };
    votes: {
        total: number;
        accepted: number;
        rejected: number;
        pending: number;
        stuckPending: number;
    };
    achievements: {
        totalUnlocked: number;
    };
    leaderboard: { username: string; wins: number; games_played: number; win_rate_pct: number }[];
};

const MODE_LABEL: Record<string, string> = { original: "🥔 Original", teleport: "🌀 Teleport", reverse: "🔁 Reverse" };
const SPEED_LABEL: Record<string, string> = { fast: "⚡ Blitz", normal: "🎯 Standard", calm: "🧊 Casual" };

function pct(part: number, total: number): number {
    if (total <= 0) return 0;
    return Math.round((part / total) * 1000) / 10;
}

export default function AdminStatsPage() {
    const supabase = getSupabaseClient();
    const { user, loading: authLoading } = useAuth();
    const [stats, setStats] = useState<Stats | null>(null);
    const [error, setError] = useState("");
    const [forbidden, setForbidden] = useState(false);
    const [loading, setLoading] = useState(true);
    const [updatedAt, setUpdatedAt] = useState<Date | null>(null);

    // Alle Zahlen kommen aus EINER SECURITY DEFINER Funktion, die serverseitig
    // profiles.is_platform_admin prüft (Migration 031) -- vorher fragte diese
    // Seite zehn Rohtabellen direkt an, ganz ohne Zugriffskontrolle.
    const load = useCallback(async () => {
        if (!user?.id) return;
        setLoading(true);
        setError("");
        setForbidden(false);
        try {
            const { data, error: rpcErr } = await supabase.rpc("rpc_get_admin_stats", { p_user_id: user.id });
            if (rpcErr) {
                if (rpcErr.message === "not_authorized") {
                    setForbidden(true);
                } else {
                    setError(rpcErr.message);
                }
                return;
            }
            setStats(data as Stats);
            setUpdatedAt(new Date());
        } catch (e: unknown) {
            setError(e instanceof Error ? e.message : "Unbekannter Fehler beim Laden der Stats.");
        } finally {
            setLoading(false);
        }
    }, [supabase, user?.id]);

    useEffect(() => {
        if (authLoading) return;
        if (!user?.id) {
            setLoading(false);
            return;
        }
        void load();
    }, [authLoading, user?.id, load]);

    if (!authLoading && !user) {
        return (
            <main className="container">
                <section className="card" aria-label="Kumpir Stats">
                    <h1 className="h1">📊 Kumpir Stats</h1>
                    <p className="p hostSub">Nur für eingeloggte Platform-Admins.</p>
                    <Link href="/login?next=/admin/stats" className="btn btnPrimary">🔓 Einloggen</Link>
                </section>
            </main>
        );
    }

    if (forbidden) {
        return (
            <main className="container">
                <section className="card" aria-label="Kumpir Stats">
                    <h1 className="h1">⛔ Kein Zugriff</h1>
                    <p className="p hostSub">Dieser Account hat keine Admin-Berechtigung für Kumpir Stats.</p>
                    <Link href="/" className="btn btnSecondary">← Startseite</Link>
                </section>
            </main>
        );
    }

    return (
        <main className="container" style={{ alignItems: "flex-start" }}>
            <div className="landingWrap" style={{ width: "min(1180px, 100%)" }}>
                <section className="card" aria-label="Kumpir Stats">
                    <header
                        style={{
                            display: "flex",
                            justifyContent: "space-between",
                            alignItems: "center",
                            flexWrap: "wrap",
                            gap: 10,
                            marginBottom: 18,
                        }}
                    >
                        <div>
                            <Link href="/admin" className="btn btnSecondary btnSmall" style={{ marginBottom: 10 }}>
                                ← Zurück zum Admin-Panel
                            </Link>
                            <h1 className="h1" style={{ marginBottom: 6 }}>📊 Kumpir Stats</h1>
                            <p className="p hostSub" style={{ marginTop: 0 }}>
                                {updatedAt ? `Zuletzt aktualisiert: ${updatedAt.toLocaleTimeString("de-DE")}` : "Lädt…"}
                            </p>
                        </div>
                        <button
                            type="button"
                            className="btn btnSecondary btnSmall"
                            onClick={() => void load()}
                            disabled={loading}
                        >
                            {loading ? <Spinner size={14} /> : "🔄 Aktualisieren"}
                        </button>
                    </header>

                    {error ? (
                        <div
                            style={{
                                background: "rgba(255,80,80,0.18)",
                                border: "1px solid rgba(255,255,255,0.3)",
                                borderRadius: 14,
                                padding: "12px 14px",
                                marginBottom: 16,
                                fontWeight: 700,
                            }}
                        >
                            ❌ {error}
                        </div>
                    ) : null}

                    {!stats ? (
                        <div style={{ display: "grid", placeItems: "center", padding: 40 }}>
                            <Spinner size={26} label="Lade Stats…" />
                        </div>
                    ) : (
                        <div style={{ display: "grid", gap: 18 }}>
                            <StatGroup title="🍟 Lobbies & Runden">
                                <Tile label="Lobbies gesamt" value={stats.lobbies.totalEver} />
                                <Tile
                                    label="Aktiv gerade jetzt"
                                    value={stats.lobbies.activeNow}
                                    tone={stats.lobbies.activeNow > 0 ? "good" : "muted"}
                                />
                                <Tile label="Neu (24h)" value={stats.lobbies.last24h} />
                                <DistTile label="Modus (alle)" entries={stats.lobbies.byMode} labelMap={MODE_LABEL} />
                                <DistTile label="Speed (alle)" entries={stats.lobbies.bySpeed} labelMap={SPEED_LABEL} />
                            </StatGroup>

                            <StatGroup title="👥 Spieler & Social">
                                <Tile label="Registrierte Nutzer" value={stats.social.registeredUsers} />
                                <Tile
                                    label="Spieler-Zeilen gesamt"
                                    value={stats.players.totalRows}
                                    sub={`davon ${pct(stats.players.botRows, stats.players.totalRows)}% Bots`}
                                />
                                <Tile label="Gerade aktiv (Zeilen)" value={stats.players.activeRows} />
                                <Tile label="Freundschaften" value={stats.social.acceptedFriendships} />
                                <Tile label="Gemerkte Lobbies" value={stats.social.savedLobbies} />
                            </StatGroup>

                            <StatGroup title="🏁 Matches">
                                <Tile label="Abgeschlossene Matches" value={stats.matches.finished} />
                                <Tile label="⌀ Spieler / Match" value={stats.matches.avgPlayers ?? "—"} />
                                <Tile
                                    label="⌀ Dauer"
                                    value={stats.matches.avgDurationSec != null ? formatDuration(stats.matches.avgDurationSec) : "—"}
                                />
                                <Tile label="Aktive Kategorien" value={stats.content.activeTopics} />
                            </StatGroup>

                            <StatGroup title="🥔 Antwort-Validierung (Topic-Mechanik B)">
                                <Tile label="Pass-Versuche gesamt" value={stats.votes.total} />
                                <Tile
                                    label="Angenommen"
                                    value={stats.votes.accepted}
                                    sub={`${pct(stats.votes.accepted, stats.votes.total)}%`}
                                    tone="good"
                                />
                                <Tile
                                    label="Abgelehnt"
                                    value={stats.votes.rejected}
                                    sub={`${pct(stats.votes.rejected, stats.votes.total)}%`}
                                    tone="warn"
                                />
                                <Tile
                                    label="Hängend (> 30s)"
                                    value={stats.votes.stuckPending}
                                    sub="Watchdog — siehe BALANCE_REPORT.md"
                                    tone={stats.votes.stuckPending > 0 ? "bad" : "good"}
                                />
                            </StatGroup>

                            <StatGroup title="🏆 Leaderboard (Top 5) & Achievements">
                                {stats.leaderboard.length === 0 ? (
                                    <div style={{ opacity: 0.75, gridColumn: "1 / -1" }}>Noch keine Einträge.</div>
                                ) : (
                                    <div style={{ gridColumn: "1 / -1", overflowX: "auto" }}>
                                        <table style={{ width: "100%", borderCollapse: "collapse" }}>
                                            <thead>
                                                <tr style={{ textAlign: "left", opacity: 0.75 }}>
                                                    <th style={{ padding: "8px 6px" }}>#</th>
                                                    <th style={{ padding: "8px 6px" }}>Name</th>
                                                    <th style={{ padding: "8px 6px" }}>Siege</th>
                                                    <th style={{ padding: "8px 6px" }}>Spiele</th>
                                                    <th style={{ padding: "8px 6px" }}>Winrate</th>
                                                </tr>
                                            </thead>
                                            <tbody>
                                                {stats.leaderboard.map((row, idx) => (
                                                    <tr key={row.username} style={{ borderTop: "1px solid rgba(255,255,255,0.12)" }}>
                                                        <td style={{ padding: "8px 6px" }}>{idx + 1}</td>
                                                        <td style={{ padding: "8px 6px", fontWeight: 900 }}>{row.username}</td>
                                                        <td style={{ padding: "8px 6px" }}>{row.wins}</td>
                                                        <td style={{ padding: "8px 6px" }}>{row.games_played}</td>
                                                        <td style={{ padding: "8px 6px" }}>{row.win_rate_pct}%</td>
                                                    </tr>
                                                ))}
                                            </tbody>
                                        </table>
                                    </div>
                                )}
                                <Tile label="Achievements freigeschaltet" value={stats.achievements.totalUnlocked} />
                            </StatGroup>

                            <StatGroup title="🔌 Infrastruktur (statisch)">
                                <InfraRow name="Datenbank" value="Supabase Postgres (RLS aktiv seit Migration 012)" />
                                <InfraRow name="Auth" value="Supabase Auth (Email/Passwort, Gastmodus per Flag)" />
                                <InfraRow name="Realtime" value="Supabase Realtime (postgres_changes) + Polling-Fallback" />
                                <InfraRow name="Hosting" value="Vercel (apps/web, Next.js)" />
                                <InfraRow name="CI" value="GitHub Actions — Lint/Test/Build auf jeden Push/PR" />
                                <InfraRow name="Discord-Bot" value="apps/discord-bot — kein Deploy-Config im Repo gefunden (vermutlich nicht aktiv)" tone="warn" />
                            </StatGroup>

                            {/* Song-Bekanntheit, Balance aus echten Spielen, Weg der Spieler (Migration 076) */}
                            <AdminAnalytics />
                        </div>
                    )}
                </section>
            </div>
        </main>
    );
}

function formatDuration(totalSeconds: number): string {
    const m = Math.floor(totalSeconds / 60);
    const s = totalSeconds % 60;
    if (m <= 0) return `${s}s`;
    return `${m}m ${s}s`;
}

function StatGroup({ title, children }: { title: string; children: React.ReactNode }) {
    return (
        <div className="stepsWrap">
            <div className="stepsBox">
                <div className="stepsTitle" style={{ marginBottom: 12 }}>{title}</div>
                <div
                    style={{
                        display: "grid",
                        gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))",
                        gap: 12,
                    }}
                >
                    {children}
                </div>
            </div>
        </div>
    );
}

type Tone = "good" | "warn" | "bad" | "muted";

const TONE_COLOR: Record<Tone, string> = {
    good: "#34d399",
    warn: "#fbbf24",
    bad: "#f87171",
    muted: "rgba(255,255,255,0.7)",
};

function Tile({ label, value, sub, tone }: { label: string; value: string | number; sub?: string; tone?: Tone }) {
    return (
        <div
            style={{
                background: "rgba(0,0,0,0.22)",
                border: "1px solid rgba(255,255,255,0.16)",
                borderRadius: 16,
                padding: "12px 14px",
                display: "flex",
                flexDirection: "column",
                gap: 4,
            }}
        >
            <div style={{ fontSize: 12, opacity: 0.75, fontWeight: 700 }}>{label}</div>
            <div
                style={{
                    fontSize: 26,
                    fontWeight: 950,
                    fontVariantNumeric: "tabular-nums",
                    color: tone ? TONE_COLOR[tone] : undefined,
                }}
            >
                {value}
            </div>
            {sub ? <div style={{ fontSize: 11, opacity: 0.65 }}>{sub}</div> : null}
        </div>
    );
}

function DistTile({
    label,
    entries,
    labelMap,
}: {
    label: string;
    entries: Record<string, number>;
    labelMap: Record<string, string>;
}) {
    const total = Object.values(entries).reduce((a, b) => a + b, 0);
    const rows = Object.entries(entries).sort((a, b) => b[1] - a[1]);
    return (
        <div
            style={{
                background: "rgba(0,0,0,0.22)",
                border: "1px solid rgba(255,255,255,0.16)",
                borderRadius: 16,
                padding: "12px 14px",
                display: "flex",
                flexDirection: "column",
                gap: 6,
                gridColumn: "span 2",
                minWidth: 220,
            }}
        >
            <div style={{ fontSize: 12, opacity: 0.75, fontWeight: 700 }}>{label}</div>
            {rows.length === 0 ? (
                <div style={{ fontSize: 12, opacity: 0.6 }}>—</div>
            ) : (
                rows.map(([key, count]) => (
                    <div key={key} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12 }}>
                        <div style={{ width: 96, flexShrink: 0 }}>{labelMap[key] ?? key}</div>
                        <div style={{ flex: 1, background: "rgba(255,255,255,0.12)", borderRadius: 999, height: 8, overflow: "hidden" }}>
                            <div
                                style={{
                                    width: `${pct(count, total)}%`,
                                    height: "100%",
                                    background: "rgba(255,255,255,0.85)",
                                    borderRadius: 999,
                                }}
                            />
                        </div>
                        <div style={{ width: 40, textAlign: "right", fontVariantNumeric: "tabular-nums" }}>{count}</div>
                    </div>
                ))
            )}
        </div>
    );
}

function InfraRow({ name, value, tone }: { name: string; value: string; tone?: Tone }) {
    return (
        <div
            style={{
                gridColumn: "1 / -1",
                display: "flex",
                gap: 10,
                alignItems: "baseline",
                borderTop: "1px solid rgba(255,255,255,0.1)",
                padding: "8px 0",
            }}
        >
            <div style={{ width: 110, flexShrink: 0, fontWeight: 900, fontSize: 13 }}>{name}</div>
            <div style={{ fontSize: 13, color: tone ? TONE_COLOR[tone] : "rgba(255,255,255,0.85)" }}>{value}</div>
        </div>
    );
}
