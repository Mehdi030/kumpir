"use client";

import React, { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";

type Row = {
    username: string;
    avatar_emoji?: string | null;
    avatar_color?: string | null;
    arena_points: number;
    sets_played: number;
    set_wins: number;
    rank: number;
};

const MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];

/**
 * Saison-Rangliste (aktueller Kalendermonat): Arena-Punkte aus allen
 * Runden eingeloggter Spieler (Migration 062/065).
 */
export function SeasonBoard() {
    const [rows, setRows] = useState<Row[] | null>(null);
    const now = new Date();
    const season = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;

    useEffect(() => {
        let cancel = false;
        void (async () => {
            const { data } = await getSupabaseClient()
                .from("season_leaderboard_view")
                .select("username,arena_points,sets_played,set_wins,rank,avatar_emoji,avatar_color")
                .eq("season", season)
                .order("rank", { ascending: true })
                .limit(10);
            if (!cancel) setRows((data ?? []) as unknown as Row[]);
        })();
        return () => {
            cancel = true;
        };
    }, [season]);

    return (
        <div style={{ marginTop: 14, padding: 14, borderRadius: 18, background: "rgba(0,0,0,0.18)", border: "1px solid rgba(255,214,10,0.28)" }}>
            <div style={{ fontWeight: 1000, fontSize: 17 }}>
                🗓️ Saison {MONTHS[now.getMonth()]} {now.getFullYear()}
            </div>
            <div style={{ fontSize: 12, opacity: 0.7, fontWeight: 700, marginBottom: 8 }}>
                Arena-Punkte aus allen Runden · setzt sich jeden Monat zurück
            </div>
            {rows === null ? (
                <div style={{ opacity: 0.7 }}>Lade …</div>
            ) : rows.length === 0 ? (
                <div style={{ opacity: 0.75, fontWeight: 700 }}>Noch niemand in dieser Saison — spiel eine Runde eingeloggt, um zu starten.</div>
            ) : (
                <div style={{ display: "grid", gap: 6 }}>
                    {rows.map((r) => (
                        <div
                            key={`${r.rank}-${r.username}`}
                            style={{ display: "grid", gridTemplateColumns: "36px 1fr auto auto", gap: 10, alignItems: "center", padding: "8px 12px", borderRadius: 12, background: "rgba(255,255,255,0.06)", fontWeight: 800 }}
                        >
                            <span>{["🥇", "🥈", "🥉"][r.rank - 1] ?? r.rank}</span>
                            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r.avatar_emoji ? <span aria-hidden style={{ marginRight: 6 }}>{r.avatar_emoji}</span> : null}
                                {r.username}
                            </span>
                            <span style={{ fontSize: 12, opacity: 0.7 }}>{r.set_wins}× Sieg · {r.sets_played} Runden</span>
                            <span style={{ color: "#ffe08a", fontWeight: 1000 }}>{r.arena_points}</span>
                        </div>
                    ))}
                </div>
            )}
        </div>
    );
}
