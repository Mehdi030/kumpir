"use client";

import React, { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { dateLocale, useI18n } from "@/lib/i18n";

type Row = {
    username: string;
    avatar_emoji?: string | null;
    avatar_color?: string | null;
    arena_points: number;
    sets_played: number;
    set_wins: number;
    rank: number;
};


/**
 * Saison-Rangliste (aktueller Kalendermonat): Arena-Punkte aus allen
 * Runden eingeloggter Spieler (Migration 062/065).
 */
export function SeasonBoard() {
    const { tr } = useI18n();
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
                🗓️ {tr("Saison {month}", { month: now.toLocaleDateString(dateLocale(), { month: "long", year: "numeric" }) })}
            </div>
            <div style={{ fontSize: 12, opacity: 0.7, fontWeight: 700, marginBottom: 8 }}>
                {tr("Arena-Punkte aus allen Runden · beginnt jeden Monat neu")}
            </div>
            {rows === null ? (
                <div style={{ opacity: 0.7 }}>{tr("Lade…")}</div>
            ) : rows.length === 0 ? (
                <div style={{ opacity: 0.75, fontWeight: 700 }}>{tr("Noch niemand in dieser Saison – spiel angemeldet eine Runde, um zu starten.")}</div>
            ) : (
                <div style={{ display: "grid", gap: 6 }}>
                    {rows.map((r) => (
                        <div
                            key={`${r.rank}-${r.username}`}
                            style={{ display: "grid", gridTemplateColumns: "36px 1fr auto auto", gap: 10, alignItems: "center", padding: "8px 12px", borderRadius: 12, background: "rgba(255,255,255,0.06)", fontWeight: 800 }}
                        >
                            <span>{["🥇", "🥈", "🥉"][r.rank - 1] ?? r.rank}</span>
                            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                                {r.username}
                            </span>
                            <span style={{ fontSize: 12, opacity: 0.7 }}>{tr("{w}× Sieg · {n} Runden", { w: r.set_wins, n: r.sets_played })}</span>
                            <span style={{ color: "#ffe08a", fontWeight: 1000 }}>{r.arena_points}</span>
                        </div>
                    ))}
                </div>
            )}
        </div>
    );
}
