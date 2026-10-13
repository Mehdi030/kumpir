"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useAuth } from "@/components/AuthProvider";
import { Spinner } from "@/components/Spinner";
import { AdminAnalytics } from "@/components/admin/AdminAnalytics";
import { HomeButton } from "@/components/BackButton";
import { dateLocale, tk, useI18n } from "@/lib/i18n";

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

const MODE_LABEL: Record<string, string> = { original: tk("🥔 Original"), teleport: tk("🌀 Teleport"), reverse: tk("🔁 Reverse") };
const SPEED_LABEL: Record<string, string> = { fast: tk("⚡ Blitz"), normal: tk("🎯 Standard"), calm: tk("🧊 Casual") };

function pct(part: number, total: number): number {
    if (total <= 0) return 0;
    return Math.round((part / total) * 1000) / 10;
}

export default function AdminStatsPage() {
    const { tr } = useI18n();
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
            setError(e instanceof Error ? e.message : tr("Unbekannter Fehler beim Laden der Stats."));
        } finally {
            setLoading(false);
        }
    }, [supabase, user?.id, tr]);

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
                <section className="card" aria-label={tr("Kumpir Stats")}>
                    <h1 className="h1">{tr("📊 Kumpir Stats")}</h1>
                    <p className="p hostSub">{tr("Nur für eingeloggte Platform-Admins.")}</p>
                    <Link href="/login?next=/admin/stats" className="btn btnPrimary">{tr("🔓 Einloggen")}</Link>
                </section>
            </main>
        );
    }

    if (forbidden) {
        return (
            <main className="container">
                <section className="card" aria-label={tr("Kumpir Stats")}>
                    <HomeButton corner />
                    <h1 className="h1">{tr("⛔ Kein Zugriff")}</h1>
                    <p className="p hostSub">{tr("Dieser Account hat keine Admin-Berechtigung für Kumpir Stats.")}</p>
                </section>
            </main>
        );
    }

    return (
        <main className="container" style={{ alignItems: "flex-start" }}>
            <div className="landingWrap" style={{ width: "min(1180px, 100%)" }}>
                <section className="card" aria-label={tr("Kumpir Stats")}>
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
                                {tr("← Zurück zum Admin-Panel")}
                            </Link>
                            <h1 className="h1" style={{ marginBottom: 6 }}>{tr("📊 Kumpir Stats")}</h1>
                            <p className="p hostSub" style={{ marginTop: 0 }}>
                                {updatedAt ? tr("Zuletzt aktualisiert: {time}", { time: updatedAt.toLocaleTimeString(dateLocale()) }) : tr("Lädt…")}
                            </p>
                        </div>
                        <button
                            type="button"
                            className="btn btnSecondary btnSmall"
                            onClick={() => void load()}
                            disabled={loading}
                        >
                            {loading ? <Spinner size={14} /> : tr("🔄 Aktualisieren")}
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
                            <Spinner size={26} label={tr("Lade Stats…")} />
                        </div>
                    ) : (
                        <div style={{ display: "grid", gap: 18 }}>
                            <StatGroup title={tr("🍟 Lobbies & Runden")}>
                                <Tile label={tr("Lobbies gesamt")} value={stats.lobbies.totalEver} />
                                <Tile
                                    label={tr("Aktiv gerade jetzt")}
                                    value={stats.lobbies.activeNow}
                                    tone={stats.lobbies.activeNow > 0 ? "good" : "muted"}
                                />
                                <Tile label={tr("Neu (24h)")} value={stats.lobbies.last24h} />
                                <DistTile label={tr("Modus (alle)")} entries={stats.lobbies.byMode} labelMap={MODE_LABEL} />
                                <DistTile label={tr("Speed (alle)")} entries={stats.lobbies.bySpeed} labelMap={SPEED_LABEL} />
                            </StatGroup>

                            <StatGroup title={tr("👥 Spieler & Social")}>
                                <Tile label={tr("Registrierte Nutzer")} value={stats.social.registeredUsers} />
                                <Tile
                                    label={tr("Spieler-Zeilen gesamt")}
                                    value={stats.players.totalRows}
                                    sub={tr("davon {n} % Bots", { n: pct(stats.players.botRows, stats.players.totalRows) })}
                                />
                                <Tile label={tr("Gerade aktiv (Zeilen)")} value={stats.players.activeRows} />
                                <Tile label={tr("Freundschaften")} value={stats.social.acceptedFriendships} />
                                <Tile label={tr("Gemerkte Lobbies")} value={stats.social.savedLobbies} />
                            </StatGroup>

                            <StatGroup title={tr("🏁 Matches")}>
                                <Tile label={tr("Abgeschlossene Matches")} value={stats.matches.finished} />
                                <Tile label={tr("⌀ Spieler / Match")} value={stats.matches.avgPlayers ?? "—"} />
                                <Tile
                                    label={tr("⌀ Dauer")}
                                    value={stats.matches.avgDurationSec != null ? formatDuration(stats.matches.avgDurationSec) : "—"}
                                />
                                <Tile label={tr("Aktive Kategorien")} value={stats.content.activeTopics} />
                            </StatGroup>

                            <StatGroup title={tr("🥔 Antwort-Validierung (Topic-Mechanik B)")}>
                                <Tile label={tr("Pass-Versuche gesamt")} value={stats.votes.total} />
                                <Tile
                                    label={tr("Angenommen")}
                                    value={stats.votes.accepted}
                                    sub={`${pct(stats.votes.accepted, stats.votes.total)}%`}
                                    tone="good"
                                />
                                <Tile
                                    label={tr("Abgelehnt")}
                                    value={stats.votes.rejected}
                                    sub={`${pct(stats.votes.rejected, stats.votes.total)}%`}
                                    tone="warn"
                                />
                                <Tile
                                    label={tr("Hängend (> 30s)")}
                                    value={stats.votes.stuckPending}
                                    sub={tr("Watchdog – siehe BALANCE_REPORT.md")}
                                    tone={stats.votes.stuckPending > 0 ? "bad" : "good"}
                                />
                            </StatGroup>

                            <StatGroup title={tr("🏆 Bestenliste (Top 5) & Erfolge")}>
                                {stats.leaderboard.length === 0 ? (
                                    <div style={{ opacity: 0.75, gridColumn: "1 / -1" }}>{tr("Noch keine Einträge.")}</div>
                                ) : (
                                    <div style={{ gridColumn: "1 / -1", overflowX: "auto" }}>
                                        <table style={{ width: "100%", borderCollapse: "collapse" }}>
                                            <thead>
                                                <tr style={{ textAlign: "left", opacity: 0.75 }}>
                                                    <th style={{ padding: "8px 6px" }}>#</th>
                                                    <th style={{ padding: "8px 6px" }}>{tr("Name")}</th>
                                                    <th style={{ padding: "8px 6px" }}>{tr("Siege")}</th>
                                                    <th style={{ padding: "8px 6px" }}>{tr("Spiele")}</th>
                                                    <th style={{ padding: "8px 6px" }}>{tr("Winrate")}</th>
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
                                <Tile label={tr("Erfolge freigeschaltet")} value={stats.achievements.totalUnlocked} />
                            </StatGroup>

                            <StatGroup title={tr("🔌 Infrastruktur (statisch)")}>
                                <InfraRow name={tr("Datenbank")} value={tr("Supabase Postgres (RLS aktiv seit Migration 012)")} />
                                <InfraRow name="Auth" value={tr("Supabase Auth (E-Mail/Passwort, Gastmodus per Flag)")} />
                                <InfraRow name="Realtime" value="Supabase Realtime (postgres_changes + broadcast) + Polling" />
                                <InfraRow name="Hosting" value="Vercel (apps/web, Next.js)" />
                                <InfraRow name="CI" value={tr("GitHub Actions – Lint/Test/Build bei jedem Push")} />
                                <InfraRow name="Discord" value={tr("Preview-Kanal per GitHub-Action, Spiel-Logs per Datenbank")} />
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
    const { tr } = useI18n();
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
                        <div style={{ width: 96, flexShrink: 0 }}>{tr(labelMap[key] ?? key)}</div>
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
