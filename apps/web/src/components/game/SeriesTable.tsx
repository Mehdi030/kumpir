"use client";

import React, { useMemo } from "react";

export type SeriesRow = {
    set_index: number;
    player_id: string;
    name: string;
    place: number;
    arena_points: number;
    song_points: number;
    is_bot?: boolean;
};

type Props = {
    rows: SeriesRow[];
    totalSets: number;
    mePlayerId?: string | null;
    /** Zwischenstand: Spalten für noch nicht gespielte Runden ausblenden. */
    playedSets: number;
    title?: string;
};

const MEDAL = ["🥇", "🥈", "🥉"];

/**
 * Gesamtwertung einer Serie: pro Spieler das Ergebnis jedes Rundes
 * (Punkte, Farbe = Platz) und die Summe. Rang = Summe der Punkte; bei
 * Gleichstand entscheiden mehr Rundensiege, dann der bessere Ø-Platz (unsichtbar).
 */
export function SeriesTable({ rows, totalSets, mePlayerId = null, playedSets, title = "Gesamtwertung" }: Props) {
    const standings = useMemo(() => {
        const byPlayer = new Map<string, { name: string; sets: Map<number, SeriesRow>; total: number; placeSum: number; n: number; wins: number }>();
        for (const r of rows) {
            const e = byPlayer.get(r.player_id) ?? { name: r.name, sets: new Map(), total: 0, placeSum: 0, n: 0, wins: 0 };
            if (r.place === 1) e.wins += 1;
            e.sets.set(r.set_index, r);
            e.total += r.arena_points;
            e.placeSum += r.place;
            e.n += 1;
            byPlayer.set(r.player_id, e);
        }
        return [...byPlayer.entries()]
            .map(([id, e]) => ({ id, ...e, avgPlace: e.n ? e.placeSum / e.n : 99 }))
            .sort((a, b) => b.total - a.total || b.wins - a.wins || a.avgPlace - b.avgPlace);
    }, [rows]);

    const setCols = Array.from({ length: Math.max(1, Math.min(playedSets, totalSets)) }, (_, i) => i + 1);

    return (
        <div className="seriesCard">
            <div className="seriesTitle">🏆 {title}</div>
            <div className="seriesScroll">
                <table className="seriesTable">
                    <thead>
                        <tr>
                            <th>#</th>
                            <th className="l">Spieler</th>
                            {setCols.map((i) => (
                                <th key={i}>R{i}</th>
                            ))}
                            <th>Gesamt</th>
                        </tr>
                    </thead>
                    <tbody>
                        {standings.map((s, idx) => (
                            <tr key={s.id} className={`${s.id === mePlayerId ? "me" : ""} ${idx === 0 ? "first" : ""}`}>
                                <td>{MEDAL[idx] ?? idx + 1}</td>
                                <td className="l nm">{s.name}</td>
                                {setCols.map((i) => {
                                    const r = s.sets.get(i);
                                    return (
                                        <td key={i}>
                                            {r ? (
                                                <span className={`setChip p${Math.min(r.place, 4)}`} title={`Runde ${i}: Platz ${r.place}`}>
                                                    {r.arena_points}
                                                </span>
                                            ) : (
                                                "—"
                                            )}
                                        </td>
                                    );
                                })}
                                <td className="tot">{s.total}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
            <div className="seriesHint">Gold, Silber, Bronze = Platz in der Runde · Rang = Summe aller Runden</div>

            <style>{`
        .seriesCard{
          border-radius: 22px;
          padding: 16px;
          background: rgba(0,0,0,.28);
          border: 1px solid rgba(255,255,255,.14);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
        }
        .seriesTitle{ font-weight: 1000; font-size: 18px; margin-bottom: 10px; }
        .seriesScroll{ overflow-x: auto; }
        .seriesTable{ width: 100%; border-collapse: separate; border-spacing: 0 6px; font-size: 14px; }
        .seriesTable th{
          font-size: 11px; font-weight: 900; letter-spacing: 1px; text-transform: uppercase;
          opacity: .7; padding: 4px 8px; text-align: center; white-space: nowrap;
        }
        .seriesTable th.l, .seriesTable td.l{ text-align: left; }
        .seriesTable td{
          padding: 8px; text-align: center; background: rgba(255,255,255,.06); white-space: nowrap;
          font-weight: 800;
        }
        .seriesTable td:first-child{ border-radius: 12px 0 0 12px; }
        .seriesTable td:last-child{ border-radius: 0 12px 12px 0; }
        .seriesTable tr.first td{ background: rgba(255,214,10,.14); }
        .seriesTable tr.me td{ box-shadow: inset 0 1px 0 rgba(34,211,238,.6), inset 0 -1px 0 rgba(34,211,238,.6); }
        .seriesTable tr.me td:first-child{ box-shadow: inset 0 1px 0 rgba(34,211,238,.6), inset 0 -1px 0 rgba(34,211,238,.6), inset 1px 0 0 rgba(34,211,238,.6); }
        .seriesTable tr.me td:last-child{ box-shadow: inset 0 1px 0 rgba(34,211,238,.6), inset 0 -1px 0 rgba(34,211,238,.6), inset -1px 0 0 rgba(34,211,238,.6); }
        .seriesTable td.nm{ max-width: 130px; overflow: hidden; text-overflow: ellipsis; font-weight: 950; }
        .seriesTable td.tot{ font-size: 17px; font-weight: 1000; color: #ffe08a; }
        .setChip{
          display:inline-block; padding: 3px 9px; border-radius: 999px; font-size: 12px;
          background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.14);
        }
        .setChip.p1{ background: rgba(255,214,10,.22); border-color: rgba(255,214,10,.55); }
        .setChip.p2{ background: rgba(200,210,225,.18); border-color: rgba(220,230,245,.45); }
        .setChip.p3{ background: rgba(205,127,50,.22); border-color: rgba(205,127,50,.5); }
        .seriesHint{ margin-top: 8px; font-size: 11px; opacity: .65; font-weight: 700; }
      `}</style>
        </div>
    );
}
