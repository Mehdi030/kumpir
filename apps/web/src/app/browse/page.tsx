"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { Spinner } from "@/components/Spinner";

type PublicLobbyRow = {
    code: string;
    game_mode: string | null;
    round_speed: string | null;
    max_players: number | null;
    topic_filter: string[] | null;
    answer_mode: string | null;
    host_name: string;
    player_count: number;
};

const MODE_LABEL: Record<string, string> = { original: "🥔 Original", teleport: "🌀 Teleport", reverse: "🔁 Reverse" };
const SPEED_LABEL: Record<string, string> = { fast: "⚡ Blitz", normal: "🎯 Standard", calm: "🧊 Casual" };

export default function BrowsePublicLobbiesPage() {
    const supabase = getSupabaseClient();
    const [rows, setRows] = useState<PublicLobbyRow[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");

    const load = useCallback(async () => {
        setLoading(true);
        setError("");
        const { data, error: err } = await supabase
            .from("public_lobbies_view")
            .select("code,game_mode,round_speed,max_players,topic_filter,answer_mode,host_name,player_count")
            .order("player_count", { ascending: false });

        if (err) {
            setError(err.message);
        } else {
            setRows((data ?? []) as PublicLobbyRow[]);
        }
        setLoading(false);
    }, [supabase]);

    useEffect(() => {
        (async () => {
            await load();
        })();
        const t = window.setInterval(() => void load(), 5000);
        return () => window.clearInterval(t);
    }, [load]);

    return (
        <main className="container">
            <section className="card" aria-label="Öffentliche Lobbys" style={{ maxWidth: 880, margin: "0 auto" }}>
                <header className="hostHeader" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 12 }}>
                    <div>
                        <h1 className="h1">🌐 Öffentliche Lobbys</h1>
                        <p className="p hostSub" style={{ marginTop: 4 }}>
                            {rows.length === 0 ? "Gerade offen: keine" : `Gerade offen: ${rows.length}`}
                        </p>
                    </div>
                    <div style={{ display: "flex", gap: 8 }}>
                        <button type="button" className="btn btnSecondary btnSmall" onClick={() => void load()} disabled={loading}>
                            {loading ? <Spinner size={14} /> : "🔄"}
                        </button>
                        <Link href="/" className="btn btnSecondary btnSmall">← Startseite</Link>
                    </div>
                </header>

                {error ? <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>{error}</div> : null}

                {loading && rows.length === 0 ? (
                    <div style={{ display: "grid", placeItems: "center", padding: 24 }}>
                        <Spinner size={24} label="Lade…" />
                    </div>
                ) : rows.length === 0 ? (
                    <div className="fieldHelp" style={{ marginTop: 16, textAlign: "center", padding: 24 }}>
                        Gerade wartet keine öffentliche Lobby auf Mitspieler. Erstell doch selbst eine mit &bdquo;🌐 Public&rdquo;!
                    </div>
                ) : (
                    <div style={{ display: "grid", gap: 10, marginTop: 14 }}>
                        {rows.map((r) => {
                            const full = r.max_players != null && r.player_count >= r.max_players;
                            return (
                                <div
                                    key={r.code}
                                    style={{
                                        background: "rgba(0,0,0,0.2)",
                                        border: "1px solid rgba(255,255,255,0.14)",
                                        borderRadius: 16,
                                        padding: "12px 16px",
                                        display: "flex",
                                        alignItems: "center",
                                        justifyContent: "space-between",
                                        flexWrap: "wrap",
                                        gap: 10,
                                    }}
                                >
                                    <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                                        <div style={{ fontWeight: 950, fontSize: 18, letterSpacing: 2 }}>{r.code}</div>
                                        <div style={{ fontSize: 13, opacity: 0.8 }}>
                                            Host: <b>{r.host_name}</b> · {MODE_LABEL[r.game_mode ?? "original"] ?? r.game_mode} ·{" "}
                                            {SPEED_LABEL[r.round_speed ?? "normal"] ?? r.round_speed}
                                            {r.answer_mode === "voice" ? " · 🎤 Mündlich" : ""}
                                            {r.topic_filter && r.topic_filter.length > 0 ? ` · 🎵 ${r.topic_filter.join(", ")}` : ""}
                                        </div>
                                    </div>

                                    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                                        <span className="pillChip" style={{ height: 30, display: "flex", alignItems: "center" }}>
                                            👥 {r.player_count}/{r.max_players}
                                        </span>
                                        <Link
                                            href={full ? "#" : `/join?code=${encodeURIComponent(r.code)}`}
                                            className={`btn btnPrimary btnSmall ${full ? "btnDisabled" : ""}`}
                                            aria-disabled={full}
                                            tabIndex={full ? -1 : 0}
                                            onClick={(e) => {
                                                if (full) e.preventDefault();
                                            }}
                                        >
                                            {full ? "Voll" : "Beitreten"}
                                        </Link>
                                    </div>
                                </div>
                            );
                        })}
                    </div>
                )}
            </section>
        </main>
    );
}
