"use client";

import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { Spinner } from "@/components/Spinner";

type Stats = {
    lobbies: {
        totalEver: number;
        activeNow: number;
        last24h: number;
        sampleSize: number;
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
        sampleSize: number;
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
const ACTIVE_PHASES = ["topic_vote", "countdown", "running", "rematch_wait"];
const STUCK_ATTEMPT_SECONDS = 30;
const RECENT_SAMPLE_SIZE = 500;

function pct(part: number, total: number): number {
    if (total <= 0) return 0;
    return Math.round((part / total) * 1000) / 10;
}

async function exactCount(
    query: PromiseLike<{ count: number | null; error: { message: string } | null }>
): Promise<number> {
    const res = await query;
    if (res.error) throw new Error(res.error.message);
    return res.count ?? 0;
}

export default function AdminStatsPage() {
    const supabase = getSupabaseClient();
    const [stats, setStats] = useState<Stats | null>(null);
    const [error, setError] = useState("");
    const [loading, setLoading] = useState(true);
    const [updatedAt, setUpdatedAt] = useState<Date | null>(null);

    const load = useCallback(async () => {
        setLoading(true);
        setError("");
        try {
            const dayAgoIso = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
            const stuckCutoffIso = new Date(Date.now() - STUCK_ATTEMPT_SECONDS * 1000).toISOString();

            const [
                lobbiesTotal,
                lobbiesActive,
                lobbiesLast24h,
                lobbiesSampleRes,
                playersTotal,
                playersBots,
                playersActive,
                matchesFinished,
                matchesSampleRes,
                registeredUsers,
                friendshipsAccepted,
                savedLobbiesCount,
                activeTopics,
                votesTotal,
                votesAccepted,
                votesRejected,
                votesPending,
                votesStuck,
                achievementsTotal,
                leaderboardRes,
            ] = await Promise.all([
                exactCount(supabase.from("lobbies").select("id", { count: "exact", head: true })),
                exactCount(supabase.from("lobbies").select("id", { count: "exact", head: true }).in("phase", ACTIVE_PHASES)),
                exactCount(supabase.from("lobbies").select("id", { count: "exact", head: true }).gte("created_at", dayAgoIso)),
                supabase
                    .from("lobbies")
                    .select("game_mode,round_speed")
                    .order("created_at", { ascending: false })
                    .limit(RECENT_SAMPLE_SIZE),
                exactCount(supabase.from("players").select("id", { count: "exact", head: true })),
                exactCount(supabase.from("players").select("id", { count: "exact", head: true }).eq("is_bot", true)),
                exactCount(supabase.from("players").select("id", { count: "exact", head: true }).eq("status", "active")),
                exactCount(supabase.from("game_runs").select("id", { count: "exact", head: true }).not("finished_at", "is", null)),
                supabase
                    .from("game_runs")
                    .select("started_at,finished_at,players_count")
                    .not("finished_at", "is", null)
                    .order("started_at", { ascending: false })
                    .limit(RECENT_SAMPLE_SIZE),
                exactCount(supabase.from("profiles").select("id", { count: "exact", head: true })),
                exactCount(supabase.from("friendships").select("user_id", { count: "exact", head: true }).eq("status", "accepted")),
                exactCount(supabase.from("saved_lobbies").select("user_id", { count: "exact", head: true })),
                exactCount(supabase.from("topic_pool").select("id", { count: "exact", head: true }).eq("active", true)),
                exactCount(supabase.from("pass_attempts").select("id", { count: "exact", head: true })),
                exactCount(supabase.from("pass_attempts").select("id", { count: "exact", head: true }).eq("status", "accepted")),
                exactCount(supabase.from("pass_attempts").select("id", { count: "exact", head: true }).eq("status", "rejected")),
                exactCount(supabase.from("pass_attempts").select("id", { count: "exact", head: true }).eq("status", "pending")),
                exactCount(
                    supabase
                        .from("pass_attempts")
                        .select("id", { count: "exact", head: true })
                        .eq("status", "pending")
                        .lt("created_at", stuckCutoffIso)
                ),
                exactCount(supabase.from("player_achievements").select("user_id", { count: "exact", head: true })),
                supabase
                    .from("leaderboard_view")
                    .select("username,wins,games_played,win_rate_pct")
                    .order("wins", { ascending: false })
                    .limit(5),
            ]);

            if (lobbiesSampleRes.error) throw lobbiesSampleRes.error;
            if (matchesSampleRes.error) throw matchesSampleRes.error;
            if (leaderboardRes.error) throw leaderboardRes.error;

            const lobbiesSample = (lobbiesSampleRes.data ?? []) as { game_mode: string | null; round_speed: string | null }[];
            const byMode: Record<string, number> = {};
            const bySpeed: Record<string, number> = {};
            for (const row of lobbiesSample) {
                const mode = row.game_mode ?? "original";
                const speed = row.round_speed ?? "normal";
                byMode[mode] = (byMode[mode] ?? 0) + 1;
                bySpeed[speed] = (bySpeed[speed] ?? 0) + 1;
            }

            const matchesSample = (matchesSampleRes.data ?? []) as {
                started_at: string;
                finished_at: string | null;
                players_count: number | null;
            }[];
            let avgPlayers: number | null = null;
            let avgDurationSec: number | null = null;
            if (matchesSample.length > 0) {
                const playerCounts = matchesSample.map((m) => m.players_count).filter((n): n is number => n != null);
                if (playerCounts.length > 0) {
                    avgPlayers = Math.round((playerCounts.reduce((a, b) => a + b, 0) / playerCounts.length) * 10) / 10;
                }
                const durations = matchesSample
                    .filter((m) => m.finished_at)
                    .map((m) => (new Date(m.finished_at as string).getTime() - new Date(m.started_at).getTime()) / 1000)
                    .filter((s) => Number.isFinite(s) && s >= 0);
                if (durations.length > 0) {
                    avgDurationSec = Math.round(durations.reduce((a, b) => a + b, 0) / durations.length);
                }
            }

            setStats({
                lobbies: {
                    totalEver: lobbiesTotal,
                    activeNow: lobbiesActive,
                    last24h: lobbiesLast24h,
                    sampleSize: lobbiesSample.length,
                    byMode,
                    bySpeed,
                },
                players: {
                    totalRows: playersTotal,
                    botRows: playersBots,
                    activeRows: playersActive,
                },
                matches: {
                    finished: matchesFinished,
                    sampleSize: matchesSample.length,
                    avgPlayers,
                    avgDurationSec,
                },
                social: {
                    registeredUsers,
                    acceptedFriendships: friendshipsAccepted,
                    savedLobbies: savedLobbiesCount,
                },
                content: {
                    activeTopics,
                },
                votes: {
                    total: votesTotal,
                    accepted: votesAccepted,
                    rejected: votesRejected,
                    pending: votesPending,
                    stuckPending: votesStuck,
                },
                achievements: {
                    totalUnlocked: achievementsTotal,
                },
                leaderboard: (leaderboardRes.data ?? []) as Stats["leaderboard"],
            });
            setUpdatedAt(new Date());
        } catch (e: unknown) {
            setError(e instanceof Error ? e.message : "Unbekannter Fehler beim Laden der Stats.");
        } finally {
            setLoading(false);
        }
    }, [supabase]);

    useEffect(() => {
        void load();
    }, [load]);

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
                                <DistTile
                                    label={`Modus (letzte ${stats.lobbies.sampleSize})`}
                                    entries={stats.lobbies.byMode}
                                    labelMap={MODE_LABEL}
                                />
                                <DistTile
                                    label={`Speed (letzte ${stats.lobbies.sampleSize})`}
                                    entries={stats.lobbies.bySpeed}
                                    labelMap={SPEED_LABEL}
                                />
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
                                <Tile
                                    label="⌀ Spieler / Match"
                                    value={stats.matches.avgPlayers ?? "—"}
                                    sub={`aus letzten ${stats.matches.sampleSize}`}
                                />
                                <Tile
                                    label="⌀ Dauer"
                                    value={stats.matches.avgDurationSec != null ? formatDuration(stats.matches.avgDurationSec) : "—"}
                                    sub={`aus letzten ${stats.matches.sampleSize}`}
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
