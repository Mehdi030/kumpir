"use client";

import { useEffect, useState } from "react";
import { Skeleton } from "@/components/Skeleton";
import { getSupabaseClient } from "@/lib/supabaseClient";
import { useI18n } from "@/lib/i18n";

export type BoardMode = "buzzer" | "year" | "letters";

type Row = { user_id: string; username: string; matches: number; wins: number; points: number; best: number; hits: number | null; answers: number | null };

/**
 * Bestenliste je Modus (Migration 136): Buzzer, Jahr raten und Roulette – gewertet nur aus Spielen mit mindestens 2 Menschen.
 * Sortiert nach Siegen, dann Gesamtpunkten.
 */
export function ModeBoard({ mode }: { mode: BoardMode }) {
    const { tr } = useI18n();
    const [res, setRes] = useState<{ mode: BoardMode; rows: Row[]; error: string } | null>(null);

    useEffect(() => {
        let alive = true;
        void (async () => {
            const { data, error } = await getSupabaseClient().rpc("get_mode_leaderboard", { p_mode: mode });
            if (alive) setRes({ mode, rows: error ? [] : ((data ?? []) as Row[]), error: error?.message ?? "" });
        })();
        return () => {
            alive = false;
        };
    }, [mode]);

    const loading = !res || res.mode !== mode;
    if (loading) {
        return <Skeleton kind="rows" count={7} label={tr("Lade…")} />;
    }
    if (res.error) return <div className="fieldHelp fieldHelpError" style={{ marginTop: 10 }}>{res.error}</div>;
    if (!res.rows.length) {
        return (
            <div className="fieldHelp" style={{ marginTop: 16, textAlign: "center", padding: 24 }}>
                {tr("Noch keine Wertung. Spielt zu zweit oder mehr mit Konto – dann tauchst du hier auf.")}
            </div>
        );
    }
    const showAcc = mode !== "letters";
    return (
        <div style={{ marginTop: 14, overflowX: "auto" }}>
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
                <thead>
                    <tr style={{ textAlign: "left", opacity: 0.7, fontSize: 12, letterSpacing: 0.6, textTransform: "uppercase" }}>
                        <th style={{ padding: "10px 8px" }}>#</th>
                        <th style={{ padding: "10px 8px" }}>{tr("Spieler")}</th>
                        <th style={{ padding: "10px 8px" }}>{tr("Spiele")}</th>
                        {showAcc ? <th style={{ padding: "10px 8px" }}>{tr("Treffer")}</th> : null}
                        <th style={{ padding: "10px 8px" }}>{tr("Punkte")}</th>
                        <th style={{ padding: "10px 8px", textAlign: "right" }}>{tr("Siege")}</th>
                    </tr>
                </thead>
                <tbody>
                    {res.rows.map((r, i) => (
                        <tr key={r.user_id} style={{ borderTop: "1px solid rgba(255,255,255,0.06)", background: i < 3 ? "rgba(255,215,0,0.06)" : "transparent" }}>
                            <td style={{ padding: "12px 8px", fontWeight: 950 }}>{i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : i + 1}</td>
                            <td style={{ padding: "12px 8px", fontWeight: 800 }}>{r.username}</td>
                            <td style={{ padding: "12px 8px", opacity: 0.85 }}>{r.matches}</td>
                            {showAcc ? (
                                <td style={{ padding: "12px 8px", opacity: 0.85 }}>{r.answers ? `${Math.round(((r.hits ?? 0) / r.answers) * 100)} %` : "—"}</td>
                            ) : null}
                            <td style={{ padding: "12px 8px", opacity: 0.85 }}>{String(Number(r.points)).replace(".", ",")}</td>
                            <td style={{ padding: "12px 8px", textAlign: "right", fontWeight: 950, fontSize: 15 }}>{r.wins}</td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    );
}
